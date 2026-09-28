# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Réaction aux paiements (D-CPP-002) : `payment.matched` et
# `payment.unmatched` publiés par le lettrage de la Comptabilité ; la
# Facturation règle la facture, l'extension note le règlement du dépôt et
# arrête son suivi. Identifiant définitif appris au suivi d'un flux.

private alias S = Choruspro::SpecSupport
private alias Api = Choruspro::Api
private alias Inv = Partiduo::Api::Invoicing

private def submission_of(view : Api::InvoiceView) : Api::SubmissionView
  view.submission || raise "facture #{view.number} sans dépôt"
end

private def matched(matching : String, invoice : Inv::DocumentView, amount : BigDecimal? = nil) : Nil
  payload = {"matching_id" => matching, "entry_ids" => "", "sources" => "invoice:#{invoice.id}"}
  payload["amounts"] = "invoice:#{invoice.id}=#{amount}" if amount
  payload["matched_on"] = "2026-10-20"
  Partiduo::Events.publish("payment.matched", payload)
  nil
end

describe "Chorus Pro — paiements (payment.matched, D-CPP-002)" do
  it "note un règlement partiel, puis le règlement complet : dépôt réglé, suivi arrêté" do
    S.books
    S.connect
    invoice = S.issue
    submission = submission_of(Api.transmit(S.admin, invoice.id).value!)
    S.chorus.advance(submission.remote_id, "MISE_A_DISPOSITION")
    Api.refresh(S.admin, invoice.id).value!

    total = Inv.document(S::SYSTEM, invoice.id).totals.payable
    matched("11", invoice, BigDecimal.new("100.00"))
    partial = submission_of(Api.invoice(S.admin, invoice.id))
    {partial.status, partial.settled_at}.should eq({"delivered", nil})
    partial.events.last.action.should eq("payment")
    partial.events.last.status.should eq("partially_paid")

    matched("12", invoice, total - BigDecimal.new("100.00"))
    matched("12", invoice, total - BigDecimal.new("100.00"))
    paid = submission_of(Api.invoice(S.admin, invoice.id))
    paid.status.should eq("paid")
    paid.settled_at.should_not be_nil
    paid.events.map(&.action).should eq(%w[submitted status payment payment])
    Inv.document(S::SYSTEM, invoice.id).status.should eq("paid")

    # Réglée : plus relevée ; un statut en retard ne la fait pas revenir.
    calls = S.chorus.calls
    Api.refresh_all(S.admin).value!.should eq(0)
    S.chorus.calls.should eq(calls)
    Api.refresh(S.admin, invoice.id).value!
    submission_of(Api.invoice(S.admin, invoice.id)).status.should eq("paid")
  end

  it "retire le règlement au délettrage et revient au dernier statut relevé" do
    S.books
    S.connect
    invoice = S.issue
    Api.transmit(S.admin, invoice.id).value!
    matched("21", invoice)
    submission_of(Api.invoice(S.admin, invoice.id)).status.should eq("paid")
    Partiduo::Events.publish("payment.unmatched", {"matching_id" => "21", "entry_ids" => "",
                                                   "sources" => "invoice:#{invoice.id}"})
    undone = submission_of(Api.invoice(S.admin, invoice.id))
    {undone.status, undone.settled_at}.should eq({"submitted", nil})
    undone.events.last.action.should eq("unpayment")
  end

  it "ignore les factures sans dépôt Chorus Pro" do
    S.books
    invoice = S.issue
    matched("31", invoice)
    Inv.document(S::SYSTEM, invoice.id).status.should eq("paid")
    Choruspro::Submission.filter(invoice_id: invoice.id).exists?.should be_false
  end

  it "retient l'identifiant définitif appris au suivi (flux intégré)" do
    S.books
    S.connect
    invoice = S.issue
    submission = submission_of(Api.transmit(S.admin, invoice.id).value!)
    S.chorus.advance(submission.remote_id, "MISE_A_DISPOSITION", resolved: "CPP-987654")
    view = submission_of(Api.refresh(S.admin, invoice.id).value!)
    {view.remote_id, view.status}.should eq({"CPP-987654", "delivered"})
    S.chorus.advance("CPP-987654", "MISE_EN_PAIEMENT")
    submission_of(Api.refresh(S.admin, invoice.id).value!).status.should eq("paid")
  end
end
