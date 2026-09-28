# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Règles ajoutées à la relecture du lot K (DECISIONS D-CPP-004 à D-CPP-009) :
# réservation du dépôt avant l'appel à Chorus Pro (dépôts simultanés,
# réponse perdue, enregistrement local en échec), visibilité limitée au
# canal Chorus Pro, historique complet (motifs et statuts), relevé général
# qui continue après l'erreur d'une facture, délettrage d'un dépôt noté à la
# main, clé de chiffrement mal formée.

private alias S = Choruspro::SpecSupport
private alias Api = Choruspro::Api
private alias Inv = Partiduo::Api::Invoicing
private alias Sim = Choruspro::SimulatedChorusPro

private def keys(result) : Array(String)
  result.errors.map(&.key)
end

private def submission_of(view : Api::InvoiceView) : Api::SubmissionView
  view.submission || raise "facture #{view.number} sans dépôt"
end

private def pending_of(id : Int64) : Choruspro::Pending
  Choruspro::Pending.filter(invoice_id: id).first || raise "aucune réservation pour #{id}"
end

private def events_of(id : Int64) : Array(Api::EventView)
  Choruspro::Deposits.events_of([id])[id]? || [] of Api::EventView
end

private def reserve(invoice : Inv::DocumentView, state : String = "running", remote_id : String = "") : Choruspro::Pending
  Choruspro::Pending.create!(invoice_id: invoice.id, reference: "PDUO-CPP-#{invoice.id}-0", state: state,
    remote_id: remote_id)
end

private def matched(matching : String, sources : String) : Nil
  Partiduo::Events.publish("payment.matched", {"matching_id" => matching, "entry_ids" => "", "sources" => sources,
                                               "matched_on" => "2026-10-20"})
  nil
end

private def unmatched(matching : String, sources : String) : Nil
  Partiduo::Events.publish("payment.unmatched", {"matching_id" => matching, "entry_ids" => "", "sources" => sources})
  nil
end

describe "Chorus Pro — règles de la relecture du lot K" do
  describe "réservation du dépôt (D-CPP-005)" do
    it "refuse un second dépôt simultané de la même facture : un seul dépôt chez Chorus Pro" do
      S.books
      S.connect
      invoice = S.issue
      inner = [] of Array(String)
      S.chorus.on_submit = -> { inner << keys(Api.transmit(S.admin, invoice.id)); nil }
      Api.transmit(S.admin, invoice.id).success?.should be_true
      inner.should eq([["choruspro.controls.deposit_running"]])
      S.chorus.deposits.size.should eq(1)
      Choruspro::Pending.all.exists?.should be_false
      keys(Api.transmit(S.admin, invoice.id)).should eq(["choruspro.controls.already_submitted"])
    end

    it "garde une réservation « sans réponse » quand la réponse se perd, et ne redépose jamais seul" do
      S.books
      S.connect
      invoice = S.issue
      S.chorus.lose_answer = true
      keys(Api.transmit(S.admin, invoice.id))
        .should eq(["choruspro.errors.transport.unavailable", "choruspro.controls.deposit_uncertain"])
      S.chorus.deposits.size.should eq(1)
      pending_of(invoice.id).state.should eq("uncertain")
      view = Api.invoice(S.admin, invoice.id)
      (view.pending || raise "réservation absente").state.should eq("uncertain")
      view.transmittable?.should be_false
      keys(Api.transmit(S.admin, invoice.id)).should eq(["choruspro.controls.deposit_uncertain"])
      S.chorus.deposits.size.should eq(1)
      Api.counts(S.admin).should eq(Api::CountsView.new(0, 1))
      events_of(invoice.id).map(&.action).should eq(["uncertain"])
      Inv.document(S::SYSTEM, invoice.id).sent_at.should be_nil

      # Retrouvée sur le portail : notée à la main, la réservation disparaît.
      noted = submission_of(Api.note_manual(S.admin, invoice.id, Api::ManualInput.new("CPP-100000")).value!)
      {noted.manual, noted.remote_id}.should eq({true, "CPP-100000"})
      Choruspro::Pending.all.exists?.should be_false
      Api.counts(S.admin).should eq(Api::CountsView.new(0, 0))
    end

    it "lève une réservation sans réponse après vérification, puis laisse déposer de nouveau" do
      S.books
      S.connect
      invoice = S.issue
      keys(Api.release(S.admin, invoice.id)).should eq(["choruspro.controls.no_pending"])
      S.chorus.failure = nil
      S.chorus.lose_answer = true
      Api.transmit(S.admin, invoice.id).success?.should be_false
      expect_raises(Partiduo::Api::Forbidden) { Api.release(S.admin([Api::READ]), invoice.id) }
      released = Api.release(S.admin, invoice.id).value!
      released.pending.should be_nil
      submission_of(Api.transmit(S.admin, invoice.id).value!).status.should eq("submitted")
      events_of(invoice.id).map(&.action).should eq(%w[uncertain released submitted])
    end

    it "refuse de lever un appel en cours, sauf s'il est interrompu depuis plus de dix minutes" do
      S.books
      S.connect
      invoice = S.issue
      reserve(invoice)
      keys(Api.release(S.admin, invoice.id)).should eq(["choruspro.controls.deposit_running"])
      keys(Api.note_manual(S.admin, invoice.id, Api::ManualInput.new)).should eq(["choruspro.controls.deposit_running"])
      Marten::DB::Connection.default.open do |db|
        db.exec("UPDATE choruspro_pending SET updated_at = $1", Time.utc - 1.hour)
      end
      Api.invoice(S.admin, invoice.id).controls.map(&.key).should eq(["choruspro.controls.deposit_uncertain"])
      Api.release(S.admin, invoice.id).success?.should be_true
      S.chorus.deposits.should be_empty
    end

    it "finalise sans nouvel appel un dépôt accepté dont l'enregistrement a échoué" do
      S.books
      S.connect
      invoice = S.issue
      reserve(invoice, remote_id: "CPP-777")
      view = Api.invoice(S.admin, invoice.id)
      (view.pending || raise "réservation absente").state.should eq("accepted")
      view.transmittable?.should be_true
      Api.counts(S.admin).should eq(Api::CountsView.new(0, 1))
      keys(Api.release(S.admin, invoice.id)).should eq(["choruspro.controls.deposit_accepted"])
      done = submission_of(Api.transmit(S.admin, invoice.id).value!)
      {done.remote_id, done.status, done.manual}.should eq({"CPP-777", "submitted", false})
      S.chorus.deposits.should be_empty
      Choruspro::Pending.all.exists?.should be_false
      Inv.document(S::SYSTEM, invoice.id).sent_at.should_not be_nil
    end

    it "garde l'identifiant rendu par Chorus Pro quand l'enregistrement local échoue" do
      S.books
      S.connect
      invoice = S.issue
      # Une ligne de dépôt apparaît pendant l'appel : l'enregistrement heurte
      # l'unicité de la facture.
      S.chorus.on_submit = -> do
        Choruspro::Submission.create!(invoice_id: invoice.id, number: invoice.number.to_s, recipient_siret: Sim::PARIS,
          remote_id: "AUTRE", submitted_at: Time.utc)
        nil
      end
      failed = Api.transmit(S.admin, invoice.id)
      keys(failed).should eq(["choruspro.errors.deposit.unrecorded"])
      failed.errors.first.params.should eq({"remote_id" => "CPP-100000"})
      pending_of(invoice.id).remote_id.should eq("CPP-100000")
      error = events_of(invoice.id).last
      {error.action, error.detail, error.params}
        .should eq({"error", "choruspro.errors.deposit.unrecorded", {"remote_id" => "CPP-100000"}})
    end
  end

  describe "visibilité (D-CPP-004)" do
    it "ne montre ni ne dépose un document hors du canal Chorus Pro jamais déposé" do
      S.books
      S.connect
      paper = Inv.issue(S::SYSTEM, Inv.create_document(S::SYSTEM, Inv::DocumentInput.new(kind: "invoice",
        customer_card_id: S.public_customer("Lycée", Sim::HOSPITAL).id,
        lines: [Inv::LineInput.new(item_card_id: S.item.id, quantity: S::Books.d("1"))],
        issue_channel: "paper")).value!.id, Inv::IssueInput.new(S::Books.date("2026-09-15"))).value!
      reader = S.admin([Api::READ, Api::TRANSMIT])
      expect_raises(Partiduo::Api::NotFound) { Api.invoice(reader, paper.id) }
      expect_raises(Partiduo::Api::NotFound) { Api.transmit(reader, paper.id) }
      expect_raises(Partiduo::Api::NotFound) { Api.note_manual(reader, paper.id, Api::ManualInput.new) }
      expect_raises(Partiduo::Api::NotFound) { Api.release(reader, paper.id) }
      S.chorus.deposits.should be_empty
      Api.invoices(reader).should be_empty
    end
  end

  describe "historique (D-CPP-007)" do
    it "garde le motif d'un refus avec ses paramètres, et distingue statut local et statut brut" do
      S.books
      S.connect
      invoice = S.issue
      S.chorus.refusal = "Numéro de facture en double"
      keys(Api.transmit(S.admin, invoice.id)).should eq(["choruspro.errors.transport.refused"])
      Choruspro::Pending.all.exists?.should be_false
      S.chorus.refusal = nil
      remote_id = submission_of(Api.transmit(S.admin, invoice.id).value!).remote_id
      S.chorus.advance(remote_id, "MISE_A_DISPOSITION")
      events = submission_of(Api.refresh(S.admin, invoice.id).value!).events
      events.map(&.action).should eq(%w[error submitted status])
      refused = events.first
      {refused.detail, refused.params}.should eq({"choruspro.errors.transport.refused", {"reason" => "Numéro de facture en double"}})
      refused.translated_detail?.should be_true
      {events[1].status, events[1].remote_status}.should eq({"submitted", "DEPOSEE"})
      {events[2].status, events[2].remote_status, events[2].status_key}
        .should eq({"delivered", "MISE_A_DISPOSITION", "choruspro.statuses.delivered"})
    end

    it "note un statut noté à la main comme statut local, sans statut brut" do
      S.books
      Choruspro::Transports.current = nil
      invoice = S.issue
      Api.note_manual(S.admin, invoice.id, Api::ManualInput.new("CPP-5")).value!
      last = submission_of(Api.note_status(S.admin, invoice.id, Api::StatusInput.new("delivered")).value!).events.last
      {last.action, last.status, last.remote_status, last.status_key}
        .should eq({"status", "delivered", "", "choruspro.statuses.delivered"})
    end
  end

  describe "relevé général" do
    it "continue après l'erreur propre à une facture et rend les changements avec les erreurs" do
      S.books
      S.connect
      lost = S.issue
      found = S.issue
      a = submission_of(Api.transmit(S.admin, lost.id).value!).remote_id
      b = submission_of(Api.transmit(S.admin, found.id).value!).remote_id
      S.chorus.states.delete(a)
      S.chorus.advance(b, "MISE_A_DISPOSITION")
      report = Api.refresh_all(S.admin).value!
      report.changed.should eq(1)
      report.errors.map { |error| {error.field, error.key} }
        .should eq([{lost.number.to_s, "choruspro.errors.transport.unknown_invoice"}])
      submission_of(Api.invoice(S.admin, found.id)).status.should eq("delivered")
      events_of(lost.id).last.action.should eq("error")
    end
  end

  describe "délettrage (D-CPP-008)" do
    it "rend à un dépôt noté à la main le statut qu'il avait avant le lettrage" do
      S.books
      Choruspro::Transports.current = nil
      invoice = S.issue
      Api.note_manual(S.admin, invoice.id, Api::ManualInput.new("CPP-8")).value!
      Api.note_status(S.admin, invoice.id, Api::StatusInput.new("delivered")).value!
      matched("51", "invoice:#{invoice.id}")
      submission_of(Api.invoice(S.admin, invoice.id)).status.should eq("paid")
      unmatched("51", "invoice:#{invoice.id}")
      view = submission_of(Api.invoice(S.admin, invoice.id))
      {view.status, view.settled_at}.should eq({"delivered", nil})
    end

    it "rétablit une suspension notée à la main avec son motif" do
      S.books
      Choruspro::Transports.current = nil
      invoice = S.issue
      Api.note_manual(S.admin, invoice.id, Api::ManualInput.new("CPP-9")).value!
      Api.note_status(S.admin, invoice.id, Api::StatusInput.new("suspended", "Bon de commande absent")).value!
      matched("52", "invoice:#{invoice.id}")
      unmatched("52", "invoice:#{invoice.id}")
      view = submission_of(Api.invoice(S.admin, invoice.id))
      {view.status, view.reason}.should eq({"suspended", "Bon de commande absent"})
    end
  end

  describe "clé de chiffrement (D-CPP-009)" do
    it "refuse une clé PARTIDUO_CHORUSPRO_KEY mal formée au lieu de la remplacer en silence" do
      S.books
      S.connect
      previous = ENV["PARTIDUO_CHORUSPRO_KEY"]?
      begin
        ENV["PARTIDUO_CHORUSPRO_KEY"] = "pas-une-cle"
        (Choruspro::Secrets.configuration_error || raise "diagnostic absent").should contain("64 caractères")
        Choruspro::Secrets.configuration_error.to_s.should_not contain("pas-une-cle")
        expect_raises(Choruspro::Secrets::Error) { Choruspro::Secrets.encrypt("x") }
        Choruspro::Deposits.credentials.should be_nil
        keys(Api.save_credentials(S.admin, Api::CredentialsInput.new(Sim::CLIENT_ID, Sim::CLIENT_SECRET, Sim::LOGIN,
          Sim::PASSWORD))).should eq(["choruspro.errors.credentials.key"])
      ensure
        previous ? (ENV["PARTIDUO_CHORUSPRO_KEY"] = previous) : ENV.delete("PARTIDUO_CHORUSPRO_KEY")
      end
      Choruspro::Secrets.configuration_error.should be_nil
      Choruspro::Deposits.credentials.should_not be_nil
    end
  end
end
