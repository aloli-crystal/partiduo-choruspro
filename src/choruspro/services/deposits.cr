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
    # l'envoi).
    def self.documents : Array(Inv::DocumentView)
      found = [] of Inv::DocumentView
      Inv::FISCAL_KINDS.each do |kind|
        offset = 0
        loop do
          page = Inv.documents(SYSTEM, Inv::DocumentQuery.new(kind: kind, limit: PAGE, offset: offset))
          found.concat(page.select(&.issue_channel.==(CHANNEL)))
          break if page.size < PAGE
          offset += PAGE
        end
      end
      found.sort_by { |view| {view.issue_date || view.created_at, view.id} }.reverse!
    end

    def self.document(id : Int64) : Inv::DocumentView
      Inv.document(SYSTEM, id)
    end

    # Vue d'une facture ; `remote` : contrôles auprès de Chorus Pro
    # (structure destinataire) si le transport et les identifiants le
    # permettent.
    def self.view(document : Inv::DocumentView, remote : Bool = false) : ApiT::InvoiceView
      submission = Submission.filter(invoice_id: document.id).first
      ApiT::InvoiceView.new(
        id: document.id, kind: document.kind, number: document.number, issue_date: document.issue_date,
        customer_name: document.customer.name, recipient_siret: document.customer.siret,
        service_code: document.buyer_reference, engagement_number: document.order_reference,
        total_gross: document.totals.payable, currency_code: document.currency_code, sent_at: document.sent_at,
        submission: submission.try { |row| submission_view(row) },
        controls: controls(document, submission, remote),
      )
    end

    # --- Contrôles ---------------------------------------------------------------

    def self.control(key : String, severity : String = "error", params = {} of String => String) : ApiT::ControlView
      ApiT::ControlView.new("choruspro.controls.#{key}", params, severity)
    end

    def self.controls(document : Inv::DocumentView, submission : Submission?, remote : Bool) : Array(ApiT::ControlView)
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
      if submission
        list << control("already_submitted", params: {"status" => submission.status.to_s}) unless resubmittable?(submission)
      elsif document.sent_at
        list << control("already_sent")
      end
      list.concat(remote_controls(document)) if remote && list.none?(&.error?)
      list
    end

    def self.resubmittable?(submission : Submission) : Bool
      Config::RESUBMITTABLE.includes?(submission.status.to_s)
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
    # Facturation (canal figé). L'appel au transport a lieu hors
    # transaction ; son échec est noté dans l'historique.
    def self.transmit!(id : Int64, actor : Partiduo::Api::Actor) : Partiduo::Api::Result(ApiT::InvoiceView)
      result = Partiduo::Api::Result(ApiT::InvoiceView)
      document = document(id)
      submission = Submission.filter(invoice_id: id).first
      checks = controls(document, submission, remote: true)
      if (transport = Transports.current).nil?
        checks = checks.reject(&.key.==("choruspro.controls.no_transport")) + [control("no_transport")]
      end
      blocking = checks.select(&.error?)
      credentials = self.credentials
      unless blocking.empty? && transport && credentials
        return result.failure(blocking.map { |item| FieldError.new(FieldError::BASE, item.key, item.params) })
      end
      attempt = submission ? submission.attempts!.to_i32 + 1 : 1
      pdf = Inv.document_pdf(SYSTEM, id)
      deposit = Deposit.new(reference: "PDUO-CPP-#{id}-#{attempt}", number: document.number.to_s,
        issue_date: document.issue_date || Partiduo::Config.today, recipient_siret: document.customer.siret,
        service_code: document.buyer_reference, engagement_number: document.order_reference,
        total_gross: document.totals.payable, currency: document.currency_code, filename: pdf.filename, pdf: pdf.content)
      remote_id = begin
        transport.submit(credentials, deposit)
      rescue ex : TransportError
        log(submission.try(&.id), id, "error", "", ex.key, actor)
        return result.failure(FieldError.new(FieldError::BASE, ex.key, ex.params))
      end
      Partiduo::Api::Transaction.run do
        row = submission || Submission.new(invoice_id: id)
        fill(row, document, attempt, actor)
        row.remote_id = remote_id
        row.save!
        log(row.id, id, "submitted", "DEPOSEE", remote_id, actor)
        Inv.mark_sent(SYSTEM, id)
        result.success(view(document(id)))
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
    def self.note_manual!(id : Int64, input : ApiT::ManualInput,
                          actor : Partiduo::Api::Actor) : Partiduo::Api::Result(ApiT::InvoiceView)
      result = Partiduo::Api::Result(ApiT::InvoiceView)
      document = document(id)
      submission = Submission.filter(invoice_id: id).first
      blocking = controls(document, submission, remote: false).select(&.error?)
      blocking << control("draft") if document.draft?
      unless blocking.empty?
        return result.failure(blocking.map { |item| FieldError.new(FieldError::BASE, item.key, item.params) })
      end
      remote_id = input.remote_id.strip
      if remote_id.size > 128
        return result.failure(FieldError.new("remote_id", "choruspro.errors.manual.remote_id"))
      end
      Partiduo::Api::Transaction.run do
        row = submission || Submission.new(invoice_id: id)
        fill(row, document, submission ? submission.attempts!.to_i32 + 1 : 1, actor)
        row.manual = true
        row.remote_id = remote_id
        row.save!
        log(row.id, id, "manual", "DEPOSEE", remote_id, actor)
        Inv.mark_sent(SYSTEM, id)
        result.success(view(document(id)))
      end
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
      log(row.id, row.invoice_id!.to_i64, "status", remote_code.presence || status, reason, actor)
    end

    # --- Historique --------------------------------------------------------------

    def self.log(submission_id, invoice_id : Int64, action : String, status : String, detail : String,
                 actor : Partiduo::Api::Actor) : Nil
      SubmissionEvent.create!(submission_id: submission_id.try(&.as(Int).to_i64), invoice_id: invoice_id,
        action: action, status: status, detail: detail[0, Math.min(detail.size, 2000)], user_id: actor.user_id,
        created_at: Time.utc)
    end

    def self.submission_view(row : Submission) : ApiT::SubmissionView
      events = SubmissionEvent.filter(invoice_id: row.invoice_id).order(:id).map do |event|
        ApiT::EventView.new(event.action.to_s, event.status.to_s, event.detail.to_s,
          event.user_id.try(&.as(Int).to_i64), event.created_at!)
      end
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
