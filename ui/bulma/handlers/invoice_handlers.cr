# SPDX-License-Identifier: AGPL-3.0-or-later

module Choruspro
  module Ui
    # `/ext/CHORUSPRO/` : factures, acomptes et avoirs au canal Chorus Pro,
    # brouillons compris, avec le statut de leur dépôt.
    class IndexHandler < Handler
      def get
        actor = current.actor
        settings = Api.settings(actor)
        invoices = Api.invoices(actor)
        page("choruspro/index.html", {
          "title"        => I18n.t("choruspro_ui.title"),
          "crumbs"       => crumbs,
          "invoices"     => listed(invoices.map { |view| Present.invoice(view, fmt) }),
          "transport"    => settings.transport,
          "unconfigured" => settings.secrets_stored ? nil : "1",
          "can_transmit" => can?(Api::TRANSMIT) ? "1" : nil,
          "can_settings" => can?(Api::SETTINGS) ? "1" : nil,
          "settings_url" => Ui.url("settings"),
          "refresh_url"  => Ui.url("refresh_all"),
        })
      end
    end

    # Relève les statuts de toutes les factures déposées.
    class RefreshAllHandler < Handler
      def get
        go(Ui.url("index"))
      end

      def post
        result = Api.refresh_all(current.actor)
        if count = result.value?
          flash["success"] = I18n.t("choruspro_ui.flash.refreshed_all", count: count)
        else
          flash["danger"] = messages(result)
        end
        go(Ui.url("index"))
      end
    end

    # `/ext/CHORUSPRO/invoices/<id>` : contrôles (auprès de Chorus Pro si
    # possible), dépôt, statut, dépôt et statut notés à la main, historique.
    class InvoiceHandler < Handler
      def get
        actor = current.actor
        view = Api.invoice(actor, params["id"].to_s.to_i64)
        transport = Api.settings(actor).transport
        title = "#{I18n.t(view.kind_key)} #{view.number || I18n.t("choruspro_ui.draft")}"
        page("choruspro/invoice.html", {
          "title"        => title,
          "crumbs"       => crumbs(title),
          "invoice"      => Present.invoice(view, fmt),
          "service"      => view.service_code.presence,
          "engagement"   => view.engagement_number.presence,
          "controls"     => listed(view.controls.map { |control| Present.control(control, fmt) }),
          "submission"   => view.submission.try { |row| submission_row(row) },
          "events"       => listed((view.submission.try(&.events) || [] of Api::EventView).map { |event| Present.event(event, fmt) }),
          "transport"    => transport,
          "document_url" => reverse("invoicing:document", id: view.id),
          "pdf_url"      => view.draft? ? nil : Ui.url("pdf", id: view.id),
          "statuses"     => Api::MANUAL_STATUS.map { |code| Ui.row({"value" => code, "label" => I18n.t("choruspro.statuses.#{code}")}) },
        }.merge(command_urls(view, !transport.nil?)))
      end

      private def submission_row(row : Api::SubmissionView) : Row
        Ui.row({
          "remote_id"     => row.remote_id.presence,
          "remote_status" => row.remote_status.presence,
          "reason"        => row.reason.presence,
          "manual"        => row.manual ? "1" : nil,
          "attempts"      => row.attempts.to_s,
          "submitted_at"  => fmt.datetime(row.submitted_at),
          "status_at"     => row.status_at.try { |time| fmt.datetime(time) },
          "settled_at"    => row.settled_at.try { |time| fmt.datetime(time) },
        })
      end

      # Commandes offertes selon le droit de déposer, le transport et l'état
      # du dépôt.
      private def command_urls(view : Api::InvoiceView, transport : Bool) : Hash(String, String?)
        urls = {"transmit_url" => nil, "refresh_url" => nil, "manual_url" => nil, "status_url" => nil} of String => String?
        return urls unless can?(Api::TRANSMIT)
        submission = view.submission
        manual = submission.try(&.manual) || false
        open = submission.nil? || submission.resubmittable?
        urls["transmit_url"] = Ui.url("transmit", id: view.id) if transport && view.transmittable?
        urls["refresh_url"] = Ui.url("refresh", id: view.id) if transport && submission && !manual
        urls["manual_url"] = Ui.url("manual", id: view.id) if !view.draft? && open && view.controls.none?(&.error?)
        urls["status_url"] = Ui.url("status", id: view.id) if manual
        urls
      end
    end

    class PdfHandler < Handler
      def get
        file = Api.pdf(current.actor, params["id"].to_s.to_i64)
        response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
        response["Content-Disposition"] = %(attachment; filename="#{file.filename}")
        response
      end
    end

    # Commandes d'une facture : GET renvoie à sa fiche.
    abstract class InvoiceCommand < Handler
      def id : Int64
        params["id"].to_s.to_i64
      end

      def get
        go(Ui.url("invoice", id: id))
      end
    end

    class TransmitHandler < InvoiceCommand
      def post
        after(Api.transmit(current.actor, id), id, "choruspro_ui.flash.transmitted")
      end
    end

    class RefreshHandler < InvoiceCommand
      def post
        after(Api.refresh(current.actor, id), id, "choruspro_ui.flash.refreshed")
      end
    end

    class ManualHandler < InvoiceCommand
      def post
        after(Api.note_manual(current.actor, id, Api::ManualInput.new(field("remote_id"))), id, "choruspro_ui.flash.manual")
      end
    end

    class StatusHandler < InvoiceCommand
      def post
        input = Api::StatusInput.new(field("status"), field("reason", strip: false).strip)
        after(Api.note_status(current.actor, id, input), id, "choruspro_ui.flash.status")
      end
    end
  end
end
