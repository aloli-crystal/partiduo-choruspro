# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Réaction aux paiements, cas limites (D-CPP-002) : dépôt rejeté ou noté à
# la main, délettrage après une mise en paiement dite par Chorus Pro ou
# après une suspension, sources inattendues, abonnés sans effet quand
# l'extension est inactive.

private alias S = Choruspro::SpecSupport
private alias Api = Choruspro::Api
private alias Inv = Partiduo::Api::Invoicing

private def submission_of(view : Api::InvoiceView) : Api::SubmissionView
  view.submission || raise "facture #{view.number} sans dépôt"
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

private def deposited(status : String? = nil, reason : String = "") : Inv::DocumentView
  invoice = S.issue
  remote_id = submission_of(Api.transmit(S.admin, invoice.id).value!).remote_id
  if status
    S.chorus.advance(remote_id, status, reason)
    Api.refresh(S.admin, invoice.id).value!
  end
  invoice
end

describe "Chorus Pro — paiements, cas limites" do
  it "note le règlement d'une facture rejetée sans changer son statut" do
    S.books
    S.connect
    invoice = deposited("REJETEE", "Doublon")
    matched("41", "invoice:#{invoice.id}")
    view = submission_of(Api.invoice(S.admin, invoice.id))
    {view.status, view.reason}.should eq({"rejected", "Doublon"})
    view.settled_at.should_not be_nil
    view.events.last.action.should eq("payment")
  end

  it "garde « payée » au délettrage si Chorus Pro a dit MISE_EN_PAIEMENT" do
    S.books
    S.connect
    invoice = deposited("MISE_EN_PAIEMENT")
    matched("42", "invoice:#{invoice.id}")
    unmatched("42", "invoice:#{invoice.id}")
    view = submission_of(Api.invoice(S.admin, invoice.id))
    {view.status, view.settled_at}.should eq({"paid", nil})
  end

  it "revient à la suspension relevée, avec son code comme motif, au délettrage" do
    S.books
    S.connect
    invoice = deposited("SUSPENDUE")
    matched("43", "invoice:#{invoice.id}")
    submission_of(Api.invoice(S.admin, invoice.id)).status.should eq("paid")
    unmatched("43", "invoice:#{invoice.id}")
    view = submission_of(Api.invoice(S.admin, invoice.id))
    {view.status, view.reason, view.settled_at}.should eq({"suspended", "SUSPENDUE", nil})
    # Plus réglée : le suivi reprend.
    S.chorus.advance(view.remote_id, "MISE_EN_PAIEMENT")
    Api.refresh_all(S.admin).value!.changed.should eq(1)
  end

  it "règle un dépôt noté à la main ; délettrer sans règlement ne note rien" do
    S.books
    Choruspro::Transports.current = nil
    invoice = S.issue
    Api.note_manual(S.admin, invoice.id, Api::ManualInput.new("CPP-9")).value!
    unmatched("44", "invoice:#{invoice.id}")
    submission_of(Api.invoice(S.admin, invoice.id)).events.map(&.action).should eq(["manual"])
    matched("44", "invoice:#{invoice.id}")
    view = submission_of(Api.invoice(S.admin, invoice.id))
    {view.status, view.manual}.should eq({"paid", true})
    view.settled_at.should_not be_nil
  end

  it "ignore les sources qui ne sont pas des factures, et traite chaque facture citée" do
    S.books
    S.connect
    one = deposited
    two = deposited
    matched("45", "entry:3, invoice:abc,,invoice:#{one.id} , invoice:#{two.id},invoice:987654321")
    [one, two].each do |invoice|
      submission_of(Api.invoice(S.admin, invoice.id)).status.should eq("paid")
    end
    Choruspro::SubmissionEvent.filter(action: "payment").count.should eq(2)
  end

  it "reste sans effet quand l'extension est inactive, sans bloquer le lettrage" do
    S.books
    S.connect
    invoice = deposited
    Partiduo::Api::Modules.deactivate(S::SYSTEM, Choruspro::CODE).value!
    matched("46", "invoice:#{invoice.id}")
    Inv.document(S::SYSTEM, invoice.id).status.should eq("paid")
    row = Choruspro::Submission.filter(invoice_id: invoice.id).first || raise "dépôt absent"
    {row.status, row.settled_at}.should eq({"submitted", nil})
  end
end
