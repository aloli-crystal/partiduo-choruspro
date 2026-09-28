# SPDX-License-Identifier: AGPL-3.0-or-later

module Choruspro
  module Ui
    # Ligne présentée à un gabarit : textes déjà mis en forme, par nom (un
    # grand `Hash` n'est pas lu par les gabarits Marten, BLOCAGES
    # B-EINV-001).
    class Row
      include Marten::Template::Object

      getter values : Hash(String, String?)

      def initialize(@values : Hash(String, String?))
      end

      def resolve_template_attribute(key : String)
        values[key]?
      end
    end

    def self.row(values : Hash(String, String?)) : Row
      Row.new(values)
    end

    def self.row(values : Hash(String, String)) : Row
      Row.new(values.transform_values(&.as(String?)))
    end

    def self.url(name : String, **params) : String
      Marten.routes.reverse("choruspro:#{name}", **params)
    end

    # Classe Bulma d'un statut de dépôt.
    def self.status_class(status : String?) : String
      case status
      when "paid", "delivered"       then "is-success"
      when "submitted"               then "is-info"
      when "rejected"                then "is-danger"
      when "suspended", "to_recycle" then "is-warning"
      else                                "is-light"
      end
    end

    module Present
      alias Api = Choruspro::Api

      def self.control(control : Api::ControlView, fmt : PartiduoUi::Format) : Row
        error = Partiduo::Api::FieldError.new(Partiduo::Api::FieldError::BASE, control.key, control.params)
        Ui.row({"message" => fmt.message(error), "error" => control.error? ? "1" : nil})
      end

      def self.invoice(view : Api::InvoiceView, fmt : PartiduoUi::Format) : Row
        submission = view.submission
        status = submission.try(&.status)
        pending = view.pending
        blocking = view.controls.count(&.error?)
        Ui.row({
          "url"          => Ui.url("invoice", id: view.id),
          "number"       => view.number || I18n.t("choruspro_ui.draft"),
          "kind"         => I18n.t(view.kind_key),
          "date"         => fmt.date(view.issue_date),
          "customer"     => view.customer_name,
          "siret"        => view.recipient_siret.presence,
          "total"        => fmt.amount(view.total_gross),
          "currency"     => view.currency_code,
          "status"       => status,
          "status_label" => status.try { |code| I18n.t("choruspro.statuses.#{code}") },
          "status_class" => Ui.status_class(status),
          "pending"      => pending.try { |row| I18n.t(row.state_key) },
          "blocking"     => blocking > 0 ? I18n.t("choruspro_ui.invoices.blocking", count: blocking) : nil,
          "ready"        => view.transmittable? && submission.nil? && pending.nil? ? "1" : nil,
          "draft"        => view.draft? ? "1" : nil,
        })
      end

      # Ligne d'historique : statut local traduit, statut brut de Chorus Pro
      # à part, motif traduit avec ses paramètres (D-CPP-007).
      def self.event(event : Api::EventView, fmt : PartiduoUi::Format) : Row
        detail = event.detail
        if event.translated_detail?
          detail = fmt.message(Partiduo::Api::FieldError.new(Partiduo::Api::FieldError::BASE, detail, event.params))
        end
        status = event.status_key.try { |key| I18n.t(key) } || event.status.presence
        Ui.row({
          "at"            => fmt.datetime(event.created_at),
          "action"        => I18n.t(event.action_key),
          "status"        => status,
          "remote_status" => event.remote_status.presence,
          "detail"        => detail.presence,
        })
      end
    end
  end
end
