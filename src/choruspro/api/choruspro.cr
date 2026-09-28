# SPDX-License-Identifier: AGPL-3.0-or-later

module Choruspro
  # Contrat public de l'extension, sur le modèle de `Partiduo::Api`
  # (DECISIONS C2) : acteur en premier argument, contrôle d'accès en
  # première ligne, objets de vue immuables, jamais un modèle Marten en
  # retour ; `ModuleDisabled` si l'extension est inactive. L'interface
  # (`ui/bulma/`) ne voit que ce module. Documentation :
  # `doc/api/choruspro.adoc`.
  module Api
    alias Actor = Partiduo::Api::Actor
    alias Guard = Partiduo::Api::Guard
    alias FieldError = Partiduo::Api::FieldError
    alias Result = Partiduo::Api::Result

    MODULE_CODE = Choruspro::CODE
    READ        = "choruspro.invoice.read"
    TRANSMIT    = "choruspro.invoice.transmit"
    SETTINGS    = "choruspro.settings.manage"

    STATUSES      = Config::STATUSES
    ENVIRONMENTS  = Config::ENVIRONMENTS
    MANUAL_STATUS = Config::STATUSES - %w[submitted]

    # --- Paramètres ------------------------------------------------------------

    def self.settings(actor : Actor) : SettingsView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      settings_view(Settings.current!, actor.can?(SETTINGS))
    end

    # Enregistre les identifiants, secrets chiffrés ; vérifiés auprès de
    # Chorus Pro si le transport est branché. Un secret vide garde celui
    # enregistré.
    def self.save_credentials(actor : Actor, input : CredentialsInput) : Result(SettingsView)
      Guard.authorize!(actor, SETTINGS, module_code: MODULE_CODE)
      settings = Settings.current!
      client_id = input.client_id.strip
      login = input.login.strip
      errors, secret, password = credential_errors(input, settings)
      return Result(SettingsView).failure(errors) unless errors.empty?

      credentials = Credentials.new(client_id, secret, login, password, input.env)
      checked = nil
      if transport = Transports.current
        begin
          transport.check(credentials)
          checked = Time.utc
        rescue ex : TransportError
          return Result(SettingsView).failure(FieldError.new("client_secret", ex.key, ex.params))
        end
      end
      sealed = begin
        Secrets.encrypt_json({"client_secret" => secret, "password" => password})
      rescue Secrets::Error
        return Result(SettingsView).failure(FieldError.new("client_secret", "choruspro.errors.credentials.key"))
      end
      Partiduo::Api::Transaction.run do
        settings.client_id = client_id
        settings.login = login
        settings.secrets = sealed
        settings.env = input.env
        settings.checked_at = checked
        settings.updated_by_id = actor.user_id
        settings.save!
        Result(SettingsView).success(settings_view(settings, true))
      end
    end

    # Contrôles de la saisie ; secrets retenus (saisis, sinon enregistrés).
    private def self.credential_errors(input : CredentialsInput, settings : Settings) : {Array(FieldError), String, String}
      errors = identity_errors(input)
      stored = stored_secrets(settings)
      # Illisibles (clé changée, valeur altérée) : bloquant seulement si un
      # secret laissé vide devait être repris ; deux secrets saisis
      # remplacent la valeur illisible.
      if stored.nil? && (input.client_secret.strip.empty? || input.password.empty?)
        errors << FieldError.new("client_secret", "choruspro.errors.credentials.unreadable")
      end
      stored ||= {} of String => String
      secret = input.client_secret.strip.presence || stored["client_secret"]? || ""
      password = input.password.presence || stored["password"]? || ""
      errors << FieldError.new("client_secret", "choruspro.errors.credentials.client_secret") if secret.empty?
      errors << FieldError.new("password", "choruspro.errors.credentials.password") if password.empty?
      {errors, secret, password}
    end

    # Application PISTE, compte technique et environnement.
    private def self.identity_errors(input : CredentialsInput) : Array(FieldError)
      errors = [] of FieldError
      client_id = input.client_id.strip
      login = input.login.strip
      errors << FieldError.new("client_id", "choruspro.errors.credentials.client_id") if client_id.empty? || client_id.size > 255
      errors << FieldError.new("login", "choruspro.errors.credentials.login") if login.empty? || login.size > 255
      errors << FieldError.new("env", "choruspro.errors.credentials.env") unless ENVIRONMENTS.includes?(input.env)
      errors
    end

    # Secrets enregistrés déchiffrés ; `nil` s'ils sont illisibles.
    private def self.stored_secrets(settings : Settings) : Hash(String, String)?
      Secrets.decrypt_json(settings.secrets.to_s)
    rescue Secrets::Error | JSON::ParseException
      nil
    end

    def self.clear_credentials(actor : Actor) : SettingsView
      Guard.authorize!(actor, SETTINGS, module_code: MODULE_CODE)
      settings = Settings.current!
      settings.client_id = ""
      settings.login = ""
      settings.secrets = ""
      settings.checked_at = nil
      settings.updated_by_id = actor.user_id
      settings.save!
      settings_view(settings, true)
    end

    private def self.settings_view(settings : Settings, manager : Bool) : SettingsView
      SettingsView.new(env: settings.env.to_s, client_id: manager ? settings.client_id.to_s : "",
        login: manager ? settings.login.to_s : "", secrets_stored: !settings.secrets.to_s.empty?,
        checked_at: settings.checked_at, transport: Transports.current.try(&.name))
    end

    # --- Factures ----------------------------------------------------------------

    # Factures, acomptes et avoirs au canal `public_portal`, brouillons compris,
    # avec leur dépôt et leurs contrôles locaux (sans appel à Chorus Pro).
    def self.invoices(actor : Actor) : Array(InvoiceView)
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      Deposits.views(Deposits.documents)
    end

    # Une facture, contrôlée auprès de Chorus Pro (structure destinataire,
    # engagement, service) si le transport et les identifiants le permettent.
    # `NotFound` pour un document hors du canal `public_portal` jamais
    # déposé : `choruspro.invoice.read` ne donne pas accès au reste de la
    # Facturation.
    def self.invoice(actor : Actor, id : Int64) : InvoiceView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      Deposits.view(Deposits.visible_document!(id), remote: true)
    end

    # Compteurs, sans contrôles ni historiques : documents du canal (filtrés
    # par PostgreSQL), dépôts et réservations en deux requêtes.
    def self.counts(actor : Actor) : CountsView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      documents = Deposits.documents
      ids = documents.map(&.id)
      return CountsView.new(0, 0) if ids.empty?
      statuses = Submission.filter(invoice_id__in: ids).to_a.to_h { |row| {row.invoice_id!.to_i64, row.status.to_s} }
      pendings = Pending.filter(invoice_id__in: ids).to_a.to_h { |row| {row.invoice_id!.to_i64, row} }
      CountsView.new(
        to_transmit: documents.count { |document| !document.draft? && document.sent_at.nil? && !statuses.has_key?(document.id) && !pendings.has_key?(document.id) },
        attention: statuses.values.count(&.in?(Config::ATTENTION)) + pendings.values.count { |row| row.accepted? || row.uncertain? },
      )
    end

    # PDF/A-3 Factur-X de la facture, à déposer sur le portail sans
    # transport.
    def self.pdf(actor : Actor, id : Int64) : FileView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      Deposits.visible_document!(id)
      file = Partiduo::Api::Invoicing.document_pdf(Deposits::SYSTEM, id)
      FileView.new(file.filename, file.content_type, file.content)
    end

    # --- Dépôt et suivi ------------------------------------------------------------

    # Dépose la facture sur Chorus Pro puis la marque envoyée. Refus :
    # brouillon, canal autre que `public_portal`, SIRET du client absent, déjà
    # déposée (« à recycler » : sur le portail), déjà envoyée autrement, dépôt
    # réservé (en cours ou à l'issue inconnue ; un dépôt accepté mais pas
    # enregistré est finalisé sans nouvel appel), transport ou
    # identifiants absents, structure inconnue, engagement ou service exigé
    # absent, service inconnu, erreur de Chorus Pro (notée dans
    # l'historique).
    def self.transmit(actor : Actor, id : Int64) : Result(InvoiceView)
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      Deposits.transmit!(id, actor)
    end

    # Relève le statut d'une facture déposée par l'API.
    def self.refresh(actor : Actor, id : Int64) : Result(InvoiceView)
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      row = Submission.filter(invoice_id: id).first
      if row.nil? || row.manual
        return Result(InvoiceView).failure(FieldError.new(FieldError::BASE, "choruspro.errors.status.not_remote"))
      end
      begin
        Deposits.refresh!(row, actor)
      rescue ex : TransportError
        Deposits.log(row.id, id, "error", "", ex.key, actor, params: ex.params)
        return Result(InvoiceView).failure(FieldError.new(FieldError::BASE, ex.key, ex.params))
      end
      Result(InvoiceView).success(Deposits.view(Deposits.document(id)))
    end

    # Relève les statuts de toutes les factures déposées par l'API et pas
    # encore réglées (ni mises en paiement, ni rejetées, ni réglées d'après
    # le lettrage). Une erreur propre à une facture (inconnue, refusée) est
    # notée dans son historique et le relevé continue ; le rapport rend le
    # nombre de changements et ces erreurs (`field` = numéro de la facture). Échec
    # seulement si le transport lui-même manque ou ne répond pas.
    def self.refresh_all(actor : Actor) : Result(RefreshReport)
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      changed = 0
      errors = [] of FieldError
      Submission.filter(manual: false, settled_at__isnull: true).exclude(status__in: %w[paid rejected]).order(:id).each do |row|
        changed += 1 if Deposits.refresh!(row, actor)
      rescue ex : TransportError
        Deposits.log(row.id, row.invoice_id!.to_i64, "error", "", ex.key, actor, params: ex.params)
        if GLOBAL_ERRORS.includes?(ex.key)
          return Result(RefreshReport).failure(FieldError.new(FieldError::BASE, ex.key, ex.params))
        end
        errors << FieldError.new(row.number.to_s, ex.key, ex.params)
      end
      Result(RefreshReport).success(RefreshReport.new(changed, errors))
    end

    # Erreurs du transport qui valent pour tous les dépôts : le relevé
    # général s'arrête.
    GLOBAL_ERRORS = %w[choruspro.controls.no_transport choruspro.controls.no_credentials
      choruspro.errors.transport.credentials choruspro.errors.transport.unavailable]

    # Lève une réservation de dépôt à l'issue inconnue, après vérification
    # sur le portail que Chorus Pro n'a pas reçu la facture ; elle pourra être
    # déposée de nouveau. Refus : aucune réservation, appel encore en cours,
    # dépôt accepté (à finaliser par `transmit`).
    def self.release(actor : Actor, id : Int64) : Result(InvoiceView)
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      Deposits.release!(id, actor)
    end

    # Dépôt fait sur le portail Chorus Pro, noté à la main (repli).
    def self.note_manual(actor : Actor, id : Int64, input : ManualInput) : Result(InvoiceView)
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      Deposits.note_manual!(id, input, actor)
    end

    # Statut d'un dépôt fait sur le portail, noté à la main.
    def self.note_status(actor : Actor, id : Int64, input : StatusInput) : Result(InvoiceView)
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      Deposits.note_status!(id, input, actor)
    end
  end
end
