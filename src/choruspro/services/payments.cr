# SPDX-License-Identifier: AGPL-3.0-or-later

module Choruspro
  # Réaction aux paiements (ADR-004 D9 révisé, ADR-003 D7) : abonné de
  # `payment.matched` et `payment.unmatched`, publiés par la Comptabilité
  # quand un encaissement est lettré (ou délettré) avec une facture. La
  # Facturation, abonnée avant l'extension (ordre des manifestes), a déjà
  # recalculé le statut de la facture ; l'extension le relit par
  # `Partiduo::Api::Invoicing` (jamais par les modèles du module) :
  #
  # * facture entièrement réglée : le dépôt est noté réglé (`settled_at`),
  #   son statut passe à `paid` s'il n'était que déposé, mis à disposition
  #   ou suspendu (l'argent est arrivé : la mise en paiement a eu lieu) ; le
  #   suivi des statuts s'arrête pour lui ;
  # * règlement partiel : seulement noté dans l'historique ;
  # * délettrage : le règlement est retiré ; un statut `paid` venu du seul
  #   lettrage (Chorus Pro n'a pas dit `MISE_EN_PAIEMENT`) revient au statut
  #   qui le précédait (`settled_from`, D-CPP-008), ou au dernier statut
  #   relevé depuis s'il est plus récent (dépôt par l'API).
  #
  # Idempotent : un même lettrage n'est noté qu'une fois par facture. Aucun
  # effet extérieur (pas d'appel à Chorus Pro dans la transaction). Interne.
  # DECISIONS D-CPP-002.
  module Payments
    alias Inv = Partiduo::Api::Invoicing

    SYSTEM = Partiduo::Api::Actor.system

    # Statuts que le règlement fait passer à `paid`.
    SETTLEABLE = %w[submitted delivered suspended]

    def self.on_matched(event : Partiduo::Events::Event) : Nil
      matching_id = event["matching_id"]
      each_submission(event) do |row, document|
        detail = "#{matching_id}:#{document.status}"
        next if SubmissionEvent.filter(invoice_id: row.invoice_id, action: "payment", detail: detail).exists?
        Deposits.log(row.id, row.invoice_id!.to_i64, "payment", document.status, detail, actor(event))
        next unless document.status == "paid" && row.settled_at.nil?
        row.settled_at = Time.utc
        if SETTLEABLE.includes?(row.status.to_s)
          row.settled_from = row.status.to_s
          row.status = "paid"
          row.reason = ""
          row.status_at = Time.utc
        end
        row.save!
      end
    end

    def self.on_unmatched(event : Partiduo::Events::Event) : Nil
      matching_id = event["matching_id"]
      each_submission(event) do |row, document|
        next if row.settled_at.nil? || document.status == "paid"
        row.settled_at = nil
        previous = previous_status(row)
        if row.status == "paid" && previous
          row.status = previous
          row.reason = previous.in?("rejected", "suspended") ? previous_reason(row) : ""
          row.status_at = Time.utc
        end
        row.settled_from = ""
        row.save!
        Deposits.log(row.id, row.invoice_id!.to_i64, "unpayment", document.status, matching_id, actor(event))
      end
    end

    # Statut à rétablir au délettrage, `nil` s'il faut garder `paid` (mise
    # en paiement dite par Chorus Pro, ou statut noté à la main avant le
    # lettrage). Dépôt par l'API : le dernier statut relevé l'emporte (il a
    # pu changer pendant le règlement) ; dépôt noté à la main : celui d'avant
    # le lettrage.
    private def self.previous_status(row : Submission) : String?
      remote = row.manual ? nil : Config.local_status(row.remote_status.to_s)
      return if remote == "paid"
      remote || row.settled_from.to_s.presence
    end

    # Motif d'une suspension rétablie : celui du dernier changement de
    # statut noté.
    private def self.previous_reason(row : Submission) : String
      last = SubmissionEvent.filter(invoice_id: row.invoice_id, action: "status").order(:id).to_a.reverse!
        .find { |event| event.status.in?("rejected", "suspended") && !event.detail.to_s.empty? }
      last.try(&.detail.to_s).presence || row.remote_status.to_s.presence || "—"
    end

    # Dépôts des factures citées par l'événement (`sources` :
    # `invoice:42,…`), avec la facture relue.
    private def self.each_submission(event : Partiduo::Events::Event, &) : Nil
      event["sources"]?.to_s.split(',').each do |source|
        kind, _, id = source.strip.partition(':')
        invoice_id = id.to_i64?
        next unless kind == "invoice" && invoice_id
        row = Submission.filter(invoice_id: invoice_id).first
        next unless row
        yield row, Inv.document(SYSTEM, invoice_id)
      end
    end

    private def self.actor(event : Partiduo::Events::Event) : Partiduo::Api::Actor
      event.actor_user_id.try { |id| Partiduo::Api::Actor.user(id, [] of String) } || SYSTEM
    end
  end
end
