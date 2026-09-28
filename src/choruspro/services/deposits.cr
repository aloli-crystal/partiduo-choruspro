# SPDX-License-Identifier: AGPL-3.0-or-later

module Choruspro
  # Contrôles, dépôt et suivi des factures aux clients publics (ADR-004 D9
  # révisé). Ne parle au cœur que par `Partiduo::Api` (ADR-006 D3). Interne ;
  # le contrat est `Choruspro::Api`.
  module Deposits
    alias Inv = Partiduo::Api::Invoicing
    alias ApiT = Choruspro::Api
    alias FieldError = Partiduo::Api::FieldError

    SYSTEM   = Partiduo::Api::Actor.system
    CHANNEL  = "public_portal"
    PAGE     = 200
    SIRET_RE = /\A[0-9]{14}\z/

    # --- Factures au canal Chorus Pro ------------------------------------------

    # Documents fiscaux au canal `public_portal`, brouillons compris, du plus
    # récent au plus ancien (le canal se relit : il reste modifiable jusqu'à
    # l'envoi). Filtrés par PostgreSQL (`DocumentQuery#issue_channel`,
    # D-CPP-004).
    def self.documents : Array(Inv::DocumentView)
      found = [] of Inv::DocumentView
      Inv::FISCAL_KINDS.each do |kind|
        offset = 0
        loop do
          page = Inv.documents(SYSTEM, Inv::DocumentQuery.new(kind: kind, issue_channel: CHANNEL, limit: PAGE, offset: offset))
          found.concat(page)
          break if page.size < PAGE
          offset += PAGE
        end
      end
      found.sort_by { |view| {view.issue_date || view.created_at, view.id} }.reverse!
    end

    def self.document(id : Int64) : Inv::DocumentView
      Inv.document(SYSTEM, id)
    end

    # Document visible par l'extension : au canal `public_portal`, ou déjà
    # déposé ou réservé par elle. Tout autre document est introuvable
    # (`choruspro.invoice.read` ne donne pas accès à toute la Facturation).
    def self.visible_document!(id : Int64) : Inv::DocumentView
      document = document(id)
      return document if document.issue_channel == CHANNEL
      return document if Submission.filter(invoice_id: id).exists? || Pending.filter(invoice_id: id).exists?
      raise Partiduo::Api::NotFound.new("choruspro_invoice", id)
    end

    # Vue d'une facture ; `remote` : contrôles auprès de Chorus Pro
    # (structure destinataire) si le transport et les identifiants le
    # permettent.
    def self.view(document : Inv::DocumentView, remote : Bool = false) : ApiT::InvoiceView
      submission = Submission.filter(invoice_id: document.id).first
      pending = Pending.filter(invoice_id: document.id).first
      events = submission ? events_of([document.id]) : {} of Int64 => Array(ApiT::EventView)
      build(document, submission, pending, events[document.id]? || [] of ApiT::EventView, remote)
    end

    # Vues de plusieurs factures, dépôts, réservations et historiques lus en
    # trois requêtes (index).
    def self.views(documents : Array(Inv::DocumentView)) : Array(ApiT::InvoiceView)
      ids = documents.map(&.id)
      return [] of ApiT::InvoiceView if ids.empty?
      submissions = Submission.filter(invoice_id__in: ids).to_a.index_by(&.invoice_id!.to_i64)
      pendings = Pending.filter(invoice_id__in: ids).to_a.index_by(&.invoice_id!.to_i64)
      events = events_of(submissions.keys)
      documents.map do |document|
        build(document, submissions[document.id]?, pendings[document.id]?, events[document.id]? || [] of ApiT::EventView, false)
      end
    end

    private def self.build(document : Inv::DocumentView, submission : Submission?, pending : Pending?,
                           events : Array(ApiT::EventView), remote : Bool) : ApiT::InvoiceView
      ApiT::InvoiceView.new(
        id: document.id, kind: document.kind, number: document.number, issue_date: document.issue_date,
        customer_name: document.customer.name, recipient_siret: document.customer.siret,
        service_code: document.buyer_reference, engagement_number: document.order_reference,
        total_gross: document.totals.payable, currency_code: document.currency_code, sent_at: document.sent_at,
        submission: submission.try { |row| submission_view(row, events) },
        controls: controls(document, submission, remote, pending),
        pending: pending.try { |row| pending_view(row) },
      )
    end

    def self.pending_view(row : Pending) : ApiT::PendingView
      state = row.accepted? ? "accepted" : (row.uncertain? ? "uncertain" : "running")
      ApiT::PendingView.new(state, row.reference.to_s, row.remote_id.to_s, row.created_at || Time.utc)
    end

    # --- Contrôles ---------------------------------------------------------------

    def self.control(key : String, severity : String = "error", params = {} of String => String) : ApiT::ControlView
      ApiT::ControlView.new("choruspro.controls.#{key}", params, severity)
    end

    def self.controls(document : Inv::DocumentView, submission : Submission?, remote : Bool,
                      pending : Pending? = nil) : Array(ApiT::ControlView)
      list = [] of ApiT::ControlView
      list << control("not_chorus_channel") unless document.issue_channel == CHANNEL
      siret = document.customer.siret
      list << control("siret_missing", params: {"customer" => document.customer.name}) unless siret.matches?(SIRET_RE)
      if document.draft?
        list << control("draft", "warning")
        if document.buyer_reference.empty? && document.order_reference.empty?
          list << control("references_hint", "warning")
        end
        return list
      end
      if pending
        list << pending_control(pending)
      elsif submission
        if submission.status == "to_recycle"
          list << control("recycle_on_portal")
        else
          list << control("already_submitted", params: {"status" => submission.status.to_s})
        end
      elsif document.sent_at
        list << control("already_sent")
      end
      list.concat(remote_controls(document)) if remote && pending.nil? && list.none?(&.error?)
      list
    end

    # Réservation en cours : appel en cours ou issue inconnue (bloquant),
    # dépôt accepté à enregistrer (« Déposer » le finalise sans nouvel appel).
    private def self.pending_control(pending : Pending) : ApiT::ControlView
      if pending.accepted?
        control("deposit_accepted", "warning", {"remote_id" => pending.remote_id.to_s})
      elsif pending.uncertain?
        control("deposit_uncertain")
      else
        control("deposit_running")
      end
    end

    # Structure destinataire chez Chorus Pro : connue, engagement et service
    # exigés présents, service actif. Sans transport : dépôt à faire sur le
    # portail (avertissement).
    def self.remote_controls(document : Inv::DocumentView) : Array(ApiT::ControlView)
      transport = Transports.current
      return [control("no_transport", "warning")] unless transport
      credentials = self.credentials
      return [control("no_credentials")] unless credentials
      structure = transport.structure(credentials, document.customer.siret)
      return [control("structure_unknown", params: {"siret" => document.customer.siret})] unless structure
      list = [] of ApiT::ControlView
      if structure.engagement_required && document.order_reference.empty?
        list << control("engagement_required", params: {"structure" => structure.name})
      end
      service = document.buyer_reference
      if structure.service_required && service.empty?
        list << control("service_required", params: {"structure" => structure.name})
      elsif !service.empty? && !structure.services.empty? && !structure.services.includes?(service)
        list << control("service_unknown", params: {"service" => service, "structure" => structure.name})
      end
      list
    rescue ex : TransportError
      [ApiT::ControlView.new(ex.key, ex.params, "error")]
    end

    # --- Identifiants ------------------------------------------------------------

    # Identifiants déchiffrés, `nil` s'ils sont incomplets ou illisibles.
    def self.credentials : Credentials?
      settings = Settings.current
      return unless settings
      return if settings.client_id.to_s.empty? || settings.login.to_s.empty? || settings.secrets.to_s.empty?
      secrets = Secrets.decrypt_json(settings.secrets.to_s)
      Credentials.new(settings.client_id.to_s, secrets["client_secret"]? || "", settings.login.to_s,
        secrets["password"]? || "", settings.env.to_s)
    rescue Secrets::Error | JSON::ParseException
      nil
    end

    # --- Dépôt -------------------------------------------------------------------

    # Dépose la facture sur Chorus Pro, puis la marque envoyée dans le module
    # Facturation (canal figé). Trois temps (D-CPP-005) :
    #
    # . réservation (`choruspro_pending`, unique par facture, écrite hors de
    #   toute transaction) : un second dépôt simultané est refusé ;
    # . appel au transport, hors transaction. Refus certain : réservation
    #   levée ; pas de réponse : réservation `uncertain`, à vérifier sur le
    #   portail avant de noter le dépôt ou de lever la réservation ; succès :
    #   identifiant écrit aussitôt dans la réservation ;
    # . enregistrement (dépôt, historique, facture envoyée) en une
    #   transaction. S'il échoue, l'identifiant reste dans la réservation et
    #   l'historique : un nouveau « Déposer » finalise sans nouvel appel.
    def self.transmit!(id : Int64, actor : Partiduo::Api::Actor) : Partiduo::Api::Result(ApiT::InvoiceView)
      result = Partiduo::Api::Result(ApiT::InvoiceView)
      document = visible_document!(id)
      if pending = Pending.filter(invoice_id: id).first
        return finalize(pending, actor) if pending.accepted?
        return failure(pending_control(pending))
      end
      submission = Submission.filter(invoice_id: id).first
      checks = controls(document, submission, remote: true)
      if (transport = Transports.current).nil?
        checks = checks.reject(&.key.==("choruspro.controls.no_transport")) + [control("no_transport")]
      end
      blocking = checks.select(&.error?)
      # Un brouillon n'a que des avertissements (contrôles locaux) : il ne se
      # dépose pas (sans numéro, il ne peut pas être marqué envoyé).
      blocking << control("draft") if document.draft?
      credentials = self.credentials
      unless blocking.empty? && transport && credentials
        return result.failure(blocking.map { |item| FieldError.new(FieldError::BASE, item.key, item.params) })
      end
      pdf = Inv.document_pdf(SYSTEM, id)
      pending = reserve(id, actor) || return failure(control("deposit_running"))
      # Dépôt ou envoi fait entre la lecture et la réservation.
      if done = Submission.filter(invoice_id: id).first
        pending.delete
        return failure(control("already_submitted", params: {"status" => done.status.to_s}))
      end
      if document(id).sent_at
        pending.delete
        return failure(control("already_sent"))
      end
      deposit = Deposit.new(reference: pending.reference.to_s, number: document.number.to_s,
        issue_date: document.issue_date || Partiduo::Config.today, recipient_siret: document.customer.siret,
        service_code: document.buyer_reference, engagement_number: document.order_reference,
        total_gross: document.totals.payable, currency: document.currency_code, filename: pdf.filename, pdf: pdf.content)
      remote_id = begin
        transport.submit(credentials, deposit)
      rescue ex : TransportError
        return submit_failed(pending, ex, actor)
      rescue ex
        # Erreur imprévue pendant l'appel : issue inconnue, comme une panne.
        submit_failed(pending, TransportError.new(TransportError::UNAVAILABLE, message: ex.class.name), actor)
        raise ex
      end
      pending.remote_id = remote_id
      pending.save!
      finalize(pending, actor)
    end

    # Réserve le dépôt ; `nil` si une réservation existe déjà (unicité en
    # base, `ON CONFLICT DO NOTHING` : l'éventuelle transaction englobante
    # n'est pas interrompue).
    private def self.reserve(id : Int64, actor : Partiduo::Api::Actor) : Pending?
      now = Time.utc
      inserted = Marten::DB::Connection.default.open do |db|
        db.query_one?("INSERT INTO choruspro_pending (invoice_id, reference, state, remote_id, user_id, created_at, " \
                      "updated_at) VALUES ($1, '', 'running', '', $2, $3, $3) ON CONFLICT (invoice_id) DO NOTHING " \
                      "RETURNING id", id, actor.user_id, now, as: Int64)
      end
      return unless inserted
      pending = Pending.get!(id: inserted)
      pending.reference = "PDUO-CPP-#{id}-#{inserted}"
      pending.save!
      pending
    end

    # Refus certain : réservation levée. Pas de réponse : réservation
    # `uncertain` (le flux a pu être accepté) ; jamais de nouvel appel
    # automatique.
    private def self.submit_failed(pending : Pending, ex : TransportError,
                                   actor : Partiduo::Api::Actor) : Partiduo::Api::Result(ApiT::InvoiceView)
      invoice_id = pending.invoice_id!.to_i64
      if ex.key == TransportError::UNAVAILABLE
        pending.state = "uncertain"
        pending.save!
        log(nil, invoice_id, "uncertain", "", ex.key, actor, params: ex.params)
        Partiduo::Api::Result(ApiT::InvoiceView).failure([
          FieldError.new(FieldError::BASE, ex.key, ex.params),
          FieldError.new(FieldError::BASE, "choruspro.controls.deposit_uncertain"),
        ])
      else
        pending.delete
        log(nil, invoice_id, "error", "", ex.key, actor, params: ex.params)
        Partiduo::Api::Result(ApiT::InvoiceView).failure(FieldError.new(FieldError::BASE, ex.key, ex.params))
      end
    end

    # Enregistre un dépôt accepté par Chorus Pro (identifiant dans la
    # réservation). Un échec laisse la réservation et une trace
    # indépendante dans l'historique.
    private def self.finalize(pending : Pending, actor : Partiduo::Api::Actor) : Partiduo::Api::Result(ApiT::InvoiceView)
      id = pending.invoice_id!.to_i64
      remote_id = pending.remote_id.to_s
      begin
        Partiduo::Api::Transaction.run do
          document = document(id)
          row = Submission.new(invoice_id: id)
          fill(row, document, 1, actor)
          row.remote_id = remote_id
          row.save!
          log(row.id, id, "submitted", "submitted", remote_id, actor, remote_status: "DEPOSEE")
          Inv.mark_sent(SYSTEM, id).value!
          pending.delete
          Partiduo::Api::Result(ApiT::InvoiceView).success(view(document(id)))
        end
      rescue
        params = {"remote_id" => remote_id}
        begin
          log(nil, id, "error", "", "choruspro.errors.deposit.unrecorded", actor, params: params)
        rescue
          # Trace impossible : l'identifiant reste dans la réservation.
        end
        Partiduo::Api::Result(ApiT::InvoiceView).failure(
          FieldError.new(FieldError::BASE, "choruspro.errors.deposit.unrecorded", params))
      end
    end

    private def self.failure(item : ApiT::ControlView) : Partiduo::Api::Result(ApiT::InvoiceView)
      Partiduo::Api::Result(ApiT::InvoiceView).failure(FieldError.new(FieldError::BASE, item.key, item.params))
    end

    # Lève une réservation à l'issue inconnue, après vérification sur le
    # portail que Chorus Pro n'a pas reçu la facture : elle pourra être
    # déposée de nouveau.
    def self.release!(id : Int64, actor : Partiduo::Api::Actor) : Partiduo::Api::Result(ApiT::InvoiceView)
      visible_document!(id)
      pending = Pending.filter(invoice_id: id).first
      return failure(control("no_pending")) unless pending
      return failure(pending_control(pending)) if pending.accepted? || !pending.uncertain?
      Partiduo::Api::Transaction.run do
        pending.delete
        log(nil, id, "released", "", pending.reference.to_s, actor)
        Partiduo::Api::Result(ApiT::InvoiceView).success(view(document(id)))
      end
    end

    private def self.fill(row : Submission, document : Inv::DocumentView, attempt : Int32,
                          actor : Partiduo::Api::Actor) : Nil
      now = Time.utc
      row.number = document.number.to_s
      row.recipient_siret = document.customer.siret
      row.service_code = document.buyer_reference
      row.engagement_number = document.order_reference
      row.status = "submitted"
      row.remote_status = "DEPOSEE"
      row.reason = ""
      row.attempts = attempt
      row.submitted_at = now
      row.submitted_by_id = actor.user_id
      row.status_at = now
    end

    # Dépôt fait sur le portail, noté à la main : la facture passe envoyée.
    # Lève aussi une réservation à l'issue inconnue (la facture a été
    # retrouvée sur le portail) ou acceptée (identifiant repris s'il n'est
    # pas saisi).
    def self.note_manual!(id : Int64, input : ApiT::ManualInput,
                          actor : Partiduo::Api::Actor) : Partiduo::Api::Result(ApiT::InvoiceView)
      result = Partiduo::Api::Result(ApiT::InvoiceView)
      document = visible_document!(id)
      submission = Submission.filter(invoice_id: id).first
      pending = Pending.filter(invoice_id: id).first
      if pending && !pending.accepted? && !pending.uncertain?
        return failure(control("deposit_running"))
      end
      blocking = controls(document, submission, remote: false).select(&.error?)
      blocking << control("draft") if document.draft?
      # Une réservation vient de Partiduo lui-même : pas un envoi autrement.
      blocking.reject!(&.key.==("choruspro.controls.already_sent")) if pending
      unless blocking.empty?
        return result.failure(blocking.map { |item| FieldError.new(FieldError::BASE, item.key, item.params) })
      end
      remote_id = input.remote_id.strip.presence || pending.try(&.remote_id.to_s) || ""
      if remote_id.size > 128
        return result.failure(FieldError.new("remote_id", "choruspro.errors.manual.remote_id"))
      end
      Partiduo::Api::Transaction.run do
        row = Submission.new(invoice_id: id)
        fill(row, document, 1, actor)
        row.manual = true
        row.remote_id = remote_id
        row.save!
        log(row.id, id, "manual", "submitted", remote_id, actor, remote_status: "DEPOSEE")
        Inv.mark_sent(SYSTEM, id).value!
        pending.try(&.delete)
        result.success(view(document(id)))
      end
    rescue ex : Exception
      raise ex unless Submission.filter(invoice_id: id).exists?
      # Dépôt enregistré en même temps par une autre requête.
      Partiduo::Api::Result(ApiT::InvoiceView).failure(
        FieldError.new(FieldError::BASE, "choruspro.controls.already_submitted", {"status" => "submitted"}))
    end

    # Statut noté à la main pour un dépôt fait sur le portail.
    def self.note_status!(id : Int64, input : ApiT::StatusInput,
                          actor : Partiduo::Api::Actor) : Partiduo::Api::Result(ApiT::InvoiceView)
      result = Partiduo::Api::Result(ApiT::InvoiceView)
      row = Submission.filter(invoice_id: id).first
      return result.failure(FieldError.new(FieldError::BASE, "choruspro.errors.status.no_submission")) unless row
      return result.failure(FieldError.new(FieldError::BASE, "choruspro.errors.status.not_manual")) unless row.manual
      unless Config::STATUSES.includes?(input.status)
        return result.failure(FieldError.new("status", "choruspro.errors.status.unknown"))
      end
      reason = input.reason.strip
      if input.status.in?("rejected", "suspended") && reason.empty?
        return result.failure(FieldError.new("reason", "choruspro.errors.status.reason"))
      end
      Partiduo::Api::Transaction.run do
        row.settled_from = "" unless row.settled_at
        apply(row, input.status, "", reason, actor)
        result.success(view(document(id)))
      end
    end

    # Relève le statut d'une facture déposée ; `false` sans changement.
    def self.refresh!(row : Submission, actor : Partiduo::Api::Actor) : Bool
      transport = Transports.current || raise TransportError.new("choruspro.controls.no_transport")
      credentials = self.credentials || raise TransportError.new("choruspro.controls.no_credentials")
      remote = transport.status(credentials, row.remote_id.to_s)
      status = Config.local_status(remote.code) || row.status.to_s
      # Réglée d'après le lettrage : un statut en retard ne la fait pas
      # revenir en arrière (D-CPP-002).
      status = "paid" if row.settled_at && Payments::SETTLEABLE.includes?(status)
      resolved = remote.remote_id.presence
      resolved = nil if resolved == row.remote_id
      return false if remote.code == row.remote_status && status == row.status && resolved.nil?
      reason = remote.reason.presence || (status.in?("rejected", "suspended") ? remote.code : "")
      Partiduo::Api::Transaction.run do
        # Identifiant de la facture chez Chorus Pro, connu une fois le flux
        # intégré (adaptateur PISTE : `flux:<numéro>` → identifiant CPP).
        resolved.try { |value| row.remote_id = value }
        apply(row, status, remote.code, reason, actor)
        Partiduo::Api::Result(Nil).success(nil)
      end
      true
    end

    private def self.apply(row : Submission, status : String, remote_code : String, reason : String,
                           actor : Partiduo::Api::Actor) : Nil
      row.status = status
      row.remote_status = remote_code unless remote_code.empty?
      row.reason = reason
      row.status_at = Time.utc
      row.save!
      # Statut local et statut brut distincts (le brut est vide pour un
      # statut noté à la main).
      log(row.id, row.invoice_id!.to_i64, "status", status, reason, actor, remote_status: remote_code)
    end

    # --- Historique --------------------------------------------------------------

    # Ligne d'historique ; `detail` : texte, identifiant ou clé i18n,
    # `params` : paramètres de la clé (JSON), `remote_status` : statut brut
    # de Chorus Pro.
    def self.log(submission_id, invoice_id : Int64, action : String, status : String, detail : String,
                 actor : Partiduo::Api::Actor, remote_status : String = "",
                 params : Hash(String, String) = {} of String => String) : Nil
      SubmissionEvent.create!(submission_id: submission_id.try(&.as(Int).to_i64), invoice_id: invoice_id,
        action: action, status: status, remote_status: remote_status[0, Math.min(remote_status.size, 40)],
        detail: detail[0, Math.min(detail.size, 2000)], params: params.empty? ? "" : params.to_json,
        user_id: actor.user_id, created_at: Time.utc)
    end

    # Historiques des factures données (dépôt, erreurs avant et après).
    def self.events_of(invoice_ids : Array(Int64)) : Hash(Int64, Array(ApiT::EventView))
      found = {} of Int64 => Array(ApiT::EventView)
      return found if invoice_ids.empty?
      SubmissionEvent.filter(invoice_id__in: invoice_ids).order(:id).each do |event|
        (found[event.invoice_id!.to_i64] ||= [] of ApiT::EventView) << ApiT::EventView.new(
          event.action.to_s, event.status.to_s, event.detail.to_s, event.user_id.try(&.as(Int).to_i64),
          event.created_at!, event.remote_status.to_s, event_params(event.params.to_s))
      end
      found
    end

    private def self.event_params(raw : String) : Hash(String, String)
      raw.empty? ? {} of String => String : Hash(String, String).from_json(raw)
    rescue JSON::ParseException | TypeCastError
      {} of String => String
    end

    def self.submission_view(row : Submission, events : Array(ApiT::EventView)? = nil) : ApiT::SubmissionView
      events ||= events_of([row.invoice_id!.to_i64])[row.invoice_id!.to_i64]? || [] of ApiT::EventView
      ApiT::SubmissionView.new(
        id: row.id!.to_i64, status: row.status.to_s, remote_id: row.remote_id.to_s,
        remote_status: row.remote_status.to_s, reason: row.reason.to_s, manual: row.manual!,
        attempts: row.attempts!.to_i32, recipient_siret: row.recipient_siret.to_s,
        service_code: row.service_code.to_s, engagement_number: row.engagement_number.to_s,
        submitted_at: row.submitted_at!, status_at: row.status_at, events: events, settled_at: row.settled_at,
      )
    end
  end
end
