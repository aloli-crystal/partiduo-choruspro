# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Dépôt des factures aux clients publics sur Chorus Pro (ADR-004 D9 révisé) :
# canal proposé, contrôles (SIRET, structure, engagement, service), dépôt
# idempotent, facture marquée envoyée, suivi des statuts, repli sans
# transport, permissions, identifiants chiffrés.

private alias S = Choruspro::SpecSupport
private alias Api = Choruspro::Api
private alias Inv = Partiduo::Api::Invoicing

private def keys(result) : Array(String)
  result.errors.map(&.key)
end

private def submission_of(view : Api::InvoiceView) : Api::SubmissionView
  view.submission || raise "facture #{view.number} sans dépôt"
end

describe "Chorus Pro — dépôts (ADR-004 D9 révisé)" do
  it "propose le canal Chorus Pro pour un client public et liste ses factures, brouillons compris" do
    S.books
    customer = S.public_customer
    Inv.propose_channel(S::SYSTEM, customer.id).channel.should eq("public_portal")
    draft = S.draft(customer, buyer_reference: nil, order_reference: nil)
    draft.issue_channel.should eq("public_portal")
    listed = Api.invoices(S.admin)
    listed.map(&.id).should eq([draft.id])
    listed.first.controls.map(&.key).should eq(%w[choruspro.controls.draft choruspro.controls.references_hint])
    listed.first.transmittable?.should be_false
  end

  it "dépose une facture émise, la marque envoyée et relève ses statuts jusqu'à la mise en paiement" do
    S.books
    S.connect
    invoice = S.issue
    view = Api.invoice(S.admin, invoice.id)
    view.controls.should be_empty
    view.transmittable?.should be_true
    {view.service_code, view.engagement_number, view.recipient_siret}
      .should eq({"FACTURES", "EJ-2026-0042", Choruspro::SimulatedChorusPro::PARIS})

    sent = Api.transmit(S.admin, invoice.id).value!
    submission = submission_of(sent)
    {submission.status, submission.remote_status, submission.attempts}.should eq({"submitted", "DEPOSEE", 1})
    deposit = S.chorus.deposits[submission.remote_id]
    {deposit.recipient_siret, deposit.service_code, deposit.engagement_number, deposit.number}
      .should eq({Choruspro::SimulatedChorusPro::PARIS, "FACTURES", "EJ-2026-0042", invoice.number})
    String.new(deposit.pdf[0, 5]).should eq("%PDF-")
    document = Inv.document(S::SYSTEM, invoice.id)
    document.sent_at.should_not be_nil
    document.channel_editable?.should be_false

    # Déjà déposée : refusée ; rien de plus chez Chorus Pro.
    keys(Api.transmit(S.admin, invoice.id)).should eq(["choruspro.controls.already_submitted"])
    S.chorus.deposits.size.should eq(1)

    S.chorus.advance(submission.remote_id, "MISE_A_DISPOSITION")
    submission_of(Api.refresh(S.admin, invoice.id).value!).status.should eq("delivered")
    S.chorus.advance(submission.remote_id, "MISE_EN_PAIEMENT")
    Api.refresh_all(S.admin).value!.should eq(1)
    final = submission_of(Api.invoice(S.admin, invoice.id))
    final.status.should eq("paid")
    final.events.map(&.action).should eq(%w[submitted status status])
    Api.counts(S.admin).should eq(Api::CountsView.new(0, 0))
  end

  it "contrôle la structure destinataire : SIRET, engagement et service exigés, service inconnu" do
    S.books
    S.connect
    no_refs = S.issue(buyer_reference: nil, order_reference: nil)
    keys(Api.transmit(S.admin, no_refs.id))
      .should eq(%w[choruspro.controls.engagement_required choruspro.controls.service_required])
    bad_service = S.issue(buyer_reference: "INCONNU")
    keys(Api.transmit(S.admin, bad_service.id)).should eq(["choruspro.controls.service_unknown"])
    unknown = S.issue(S.public_customer("Mairie inconnue", "21440109300015"))
    keys(Api.transmit(S.admin, unknown.id)).should eq(["choruspro.controls.structure_unknown"])
    no_siret = S.issue(S.public_customer("Commune sans SIRET", nil, siren: "217500016"))
    keys(Api.transmit(S.admin, no_siret.id)).should eq(["choruspro.controls.siret_missing"])
    hospital = S.public_customer("CHU de Nantes", Choruspro::SimulatedChorusPro::HOSPITAL)
    Api.transmit(S.admin, S.issue(hospital, buyer_reference: nil, order_reference: nil).id).success?.should be_true
    S.chorus.deposits.size.should eq(1)
    Api.counts(S.admin).to_transmit.should eq(4)
  end

  it "refuse une facture hors canal, un transport absent ou des identifiants absents ; note l'erreur de Chorus Pro" do
    S.books
    paper = Inv.issue(S::SYSTEM, Inv.create_document(S::SYSTEM, Inv::DocumentInput.new(kind: "invoice",
      customer_card_id: S.public_customer.id, lines: [Inv::LineInput.new(item_card_id: S.item.id, quantity: S::Books.d("1"))],
      issue_channel: "paper")).value!.id, Inv::IssueInput.new(S::Books.date("2026-09-15"))).value!
    keys(Api.transmit(S.admin, paper.id)).should contain("choruspro.controls.not_chorus_channel")

    invoice = S.issue
    keys(Api.transmit(S.admin, invoice.id)).should eq(["choruspro.controls.no_credentials"])
    S.connect
    S.chorus.refusal = "Montant incohérent"
    refused = Api.transmit(S.admin, invoice.id)
    keys(refused).should eq(["choruspro.errors.transport.refused"])
    refused.errors.first.params.should eq({"reason" => "Montant incohérent"})
    Api.invoice(S.admin, invoice.id).submission.should be_nil
    Inv.document(S::SYSTEM, invoice.id).sent_at.should be_nil
    Choruspro::SubmissionEvent.filter(invoice_id: invoice.id).first.try(&.action).should eq("error")

    Choruspro::Transports.current = nil
    keys(Api.transmit(S.admin, invoice.id)).should eq(["choruspro.controls.no_transport"])
  end

  it "note à la main un dépôt fait sur le portail, puis son statut ; un rejet exige un motif" do
    S.books
    Choruspro::Transports.current = nil
    invoice = S.issue
    Api.invoice(S.admin, invoice.id).controls.map(&.key).should eq(["choruspro.controls.no_transport"])
    Api.pdf(S.admin, invoice.id).filename.should eq("#{invoice.number}.pdf")
    noted = Api.note_manual(S.admin, invoice.id, Api::ManualInput.new("CPP-PORTAIL-12")).value!
    submission = submission_of(noted)
    {submission.manual, submission.remote_id, submission.status}.should eq({true, "CPP-PORTAIL-12", "submitted"})
    Inv.document(S::SYSTEM, invoice.id).sent_at.should_not be_nil

    keys(Api.note_status(S.admin, invoice.id, Api::StatusInput.new("rejected"))).should eq(["choruspro.errors.status.reason"])
    keys(Api.note_status(S.admin, invoice.id, Api::StatusInput.new("lost"))).should eq(["choruspro.errors.status.unknown"])
    rejected = Api.note_status(S.admin, invoice.id, Api::StatusInput.new("rejected", "Service fait non constaté")).value!
    {submission_of(rejected).status, submission_of(rejected).reason}.should eq({"rejected", "Service fait non constaté"})
    keys(Api.refresh(S.admin, invoice.id)).should eq(["choruspro.errors.status.not_remote"])
    Api.counts(S.admin).attention.should eq(1)
  end

  it "dépose de nouveau une facture « à recycler » avec une nouvelle référence" do
    S.books
    S.connect
    invoice = S.issue
    first = submission_of(Api.transmit(S.admin, invoice.id).value!)
    S.chorus.advance(first.remote_id, "A_RECYCLER", "Service destinataire erroné")
    recycled = Api.refresh(S.admin, invoice.id).value!
    submission_of(recycled).status.should eq("to_recycle")
    recycled.transmittable?.should be_true
    again = submission_of(Api.transmit(S.admin, invoice.id).value!)
    again.attempts.should eq(2)
    again.remote_id.should_not eq(first.remote_id)
    S.chorus.remote_ids.keys.should eq(["PDUO-CPP-#{invoice.id}-1", "PDUO-CPP-#{invoice.id}-2"])
  end

  it "chiffre les identifiants, ne rend jamais les secrets, les vérifie auprès de Chorus Pro" do
    S.books
    bad = Api.save_credentials(S.admin, Api::CredentialsInput.new(Choruspro::SimulatedChorusPro::CLIENT_ID, "faux",
      Choruspro::SimulatedChorusPro::LOGIN, "faux"))
    keys(bad).should eq(["choruspro.errors.transport.credentials"])
    S.connect
    row = (Choruspro::Settings.current || raise "paramètres absents")
    row.secrets.to_s.should start_with("v1:")
    row.secrets.to_s.should_not contain(Choruspro::SimulatedChorusPro::PASSWORD)
    view = Api.settings(S.admin)
    {view.secrets_stored, view.client_id, view.transport}.should eq({true, Choruspro::SimulatedChorusPro::CLIENT_ID, "Chorus Pro simulé"})
    view.checked_at.should_not be_nil
    Api.settings(S.admin([Api::READ])).client_id.should eq("")
    # Secret vide : celui enregistré est gardé.
    Api.save_credentials(S.admin, Api::CredentialsInput.new(Choruspro::SimulatedChorusPro::CLIENT_ID, "",
      Choruspro::SimulatedChorusPro::LOGIN, "", "production")).value!.env.should eq("production")
    Api.clear_credentials(S.admin).secrets_stored.should be_false
  end

  it "exige ses permissions et l'activation de l'extension ; garde les dépôts (base)" do
    S.books
    S.connect
    invoice = S.issue
    expect_raises(Partiduo::Api::Forbidden) { Api.transmit(S.admin([Api::READ]), invoice.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.save_credentials(S.admin([Api::READ, Api::TRANSMIT]), Api::CredentialsInput.new("a", "b", "c", "d")) }
    Api.transmit(S.admin, invoice.id).value!
    expect_raises(Exception, /suppression interdite/) { Choruspro::Submission.all.first.try(&.delete) }
    Partiduo::Api::Modules.deactivate(S::SYSTEM, Choruspro::CODE)
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.invoices(S.admin) }
  end
end
