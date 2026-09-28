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
      Partiduo::Api::Transaction.run do
        settings.client_id = client_id
        settings.login = login
        settings.secrets = Secrets.encrypt_json({"client_secret" => secret, "password" => password})
        settings.env = input.env
        settings.checked_at = checked
        settings.updated_by_id = actor.user_id
        settings.save!
        Result(SettingsView).success(settings_view(settings, true))
      end
    end

    # Contrôles de la saisie ; secrets retenus (saisis, sinon enregistrés).
    private def self.credential_errors(input : CredentialsInput, settings : Settings) : {Array(FieldError), String, String}
      errors = [] of FieldError
      client_id = input.client_id.strip
      login = input.login.strip
      errors << FieldError.new("client_id", "choruspro.errors.credentials.client_id") if client_id.empty? || client_id.size > 255
      errors << FieldError.new("login", "choruspro.errors.credentials.login") if login.empty? || login.size > 255
      errors << FieldError.new("env", "choruspro.errors.credentials.env") unless ENVIRONMENTS.includes?(input.env)
      stored = {} of String => String
      begin
        stored = Secrets.decrypt_json(settings.secrets.to_s)
      rescue Secrets::Error | JSON::ParseException
        errors << FieldError.new("client_secret", "choruspro.errors.credentials.unreadable")
      end
      secret = input.client_secret.strip.presence || stored["client_secret"]? || ""
      password = input.password.presence || stored["password"]? || ""
      errors << FieldError.new("client_secret", "choruspro.errors.credentials.client_secret") if secret.empty?
      errors << FieldError.new("password", "choruspro.errors.credentials.password") if password.empty?
      {errors, secret, password}
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

    # Factures, acomptes et avoirs au canal `chorus_pro`, brouillons compris,
    # avec leur dépôt et leurs contrôles locaux (sans appel à Chorus Pro).
    def self.invoices(actor : Actor) : Array(InvoiceView)
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      Deposits.documents.map { |document| Deposits.view(document) }
    end

    # Une facture, contrôlée auprès de Chorus Pro (structure destinataire,
    # engagement, service) si le transport et les identifiants le permettent.
    def self.invoice(actor : Actor, id : Int64) : InvoiceView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      Deposits.view(Deposits.document(id), remote: true)
    end

    def self.counts(actor : Actor) : CountsView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      views = invoices(actor)
      CountsView.new(
        to_transmit: views.count { |view| !view.draft? && (view.submission.nil? || view.submission.try(&.resubmittable?)) && view.sent_at.nil? },
        attention: views.count { |view| view.submission.try(&.status.in?("rejected", "suspended", "to_recycle")) || false },
      )
    end

    # PDF/A-3 Factur-X de la facture, à déposer sur le portail sans
    # transport.
    def self.pdf(actor : Actor, id : Int64) : FileView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      document = Deposits.document(id)
      raise Partiduo::Api::NotFound.new("choruspro_invoice", id) unless document.issue_channel == Deposits::CHANNEL
      file = Partiduo::Api::Invoicing.document_pdf(Deposits::SYSTEM, id)
      FileView.new(file.filename, file.content_type, file.content)
    end

    # --- Dépôt et suivi ------------------------------------------------------------

    # Dépose la facture sur Chorus Pro puis la marque envoyée. Refus :
    # brouillon, canal autre que `chorus_pro`, SIRET du client absent, déjà
    # déposée (sauf « à recycler »), déjà envoyée autrement, transport ou
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
        Deposits.log(row.id, id, "error", "", ex.key, actor)
        return Result(InvoiceView).failure(FieldError.new(FieldError::BASE, ex.key, ex.params))
      end
      Result(InvoiceView).success(Deposits.view(Deposits.document(id)))
    end

    # Relève les statuts de toutes les factures déposées par l'API et pas
    # encore réglées ; rend le nombre de changements.
    def self.refresh_all(actor : Actor) : Result(Int32)
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      changed = 0
      Submission.filter(manual: false).exclude(status__in: %w[paid rejected]).order(:id).each do |row|
        changed += 1 if Deposits.refresh!(row, actor)
      rescue ex : TransportError
        Deposits.log(row.id, row.invoice_id!.to_i64, "error", "", ex.key, actor)
        return Result(Int32).failure(FieldError.new(FieldError::BASE, ex.key, ex.params))
      end
      Result(Int32).success(changed)
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
