# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Choruspro::SpecSupport

private def signed_in : PartiduoUi::Browser
  S.books
  PartiduoUi::Accounts.signed_in
end

describe "Écran Chorus Pro sous /ext/CHORUSPRO/ (ADR-005 D4, ADR-004 D9 révisé)" do
  it "est montée sous le code de l'extension, avec la permission de lecture" do
    Marten.routes.reverse("choruspro:index").should eq("/ext/CHORUSPRO/")
    mount = PartiduoUi::Extensions["CHORUSPRO"]? || raise("interface non montée")
    mount.permission.should eq(Choruspro::Api::READ)
  end

  it "n'existe pas tant que l'extension est inactive (404)" do
    PartiduoUi::Reference.provision("fr")
    PartiduoUi::Accounts.create
    PartiduoUi::Accounts.signed_in.get("/ext/CHORUSPRO/").status.should eq(404)
  end

  it "enregistre les identifiants, liste les factures, dépose et relève le statut" do
    browser = signed_in
    settings = browser.get("/ext/CHORUSPRO/settings").html
    settings.should contain(%(data-choruspro-env="qualification"))
    refused = browser.post("/ext/CHORUSPRO/settings", {"env" => "qualification", "client_id" => "", "client_secret" => "",
                                                       "login" => "", "password" => ""})
    refused.status.should eq(422)
    refused.html.should contain("Indiquez l'identifiant de l'application PISTE.")
    saved = browser.post("/ext/CHORUSPRO/settings", {
      "env" => "qualification", "client_id" => Choruspro::SimulatedChorusPro::CLIENT_ID,
      "client_secret" => Choruspro::SimulatedChorusPro::CLIENT_SECRET, "login" => Choruspro::SimulatedChorusPro::LOGIN,
      "password" => Choruspro::SimulatedChorusPro::PASSWORD,
    })
    browser.follow(saved).html.should contain("Identifiants enregistrés.")
    browser.get("/ext/CHORUSPRO/settings").html.should_not contain(Choruspro::SimulatedChorusPro::PASSWORD)

    invoice = S.issue
    index = browser.get("/ext/CHORUSPRO/").html
    index.should contain(%(data-choruspro-transport="available"))
    index.should contain("Ville de Paris")
    index.should contain("Prête")
    page = browser.get("/ext/CHORUSPRO/invoices/#{invoice.id}").html
    page.should contain("EJ-2026-0042")
    page.should contain("data-choruspro-transmit")
    transmitted = browser.post("/ext/CHORUSPRO/invoices/#{invoice.id}/transmit")
    browser.follow(transmitted).html.should contain("Facture déposée sur Chorus Pro.")
    remote_id = S.chorus.deposits.keys.first
    S.chorus.advance(remote_id, "SUSPENDUE", "Pièce justificative manquante")
    browser.follow(browser.post("/ext/CHORUSPRO/invoices/#{invoice.id}/refresh")).html.should contain("Pièce justificative manquante")
    browser.get("/ext/CHORUSPRO/").html.should contain(%(data-choruspro-status="suspended"))
  end

  it "sans connexion, propose le PDF et note le dépôt fait sur le portail" do
    browser = signed_in
    Choruspro::Transports.current = nil
    invoice = S.issue
    page = browser.get("/ext/CHORUSPRO/invoices/#{invoice.id}").html
    page.should_not contain("data-choruspro-transmit")
    page.should contain("data-choruspro-manual")
    pdf = browser.get("/ext/CHORUSPRO/invoices/#{invoice.id}/pdf")
    pdf.status.should eq(200)
    pdf.content_type.should start_with("application/pdf")
    noted = browser.post("/ext/CHORUSPRO/invoices/#{invoice.id}/manual", {"remote_id" => "CPP-12"})
    browser.follow(noted).html.should contain("Dépôt noté ; facture marquée envoyée.")
    status = browser.post("/ext/CHORUSPRO/invoices/#{invoice.id}/status", {"status" => "paid", "reason" => ""})
    browser.follow(status).html.should contain(%(data-choruspro-status="paid"))
  end

  it "affiche le règlement constaté par le lettrage (payment.matched)" do
    browser = signed_in
    S.connect
    invoice = S.issue
    Choruspro::Api.transmit(S.admin, invoice.id).value!
    Partiduo::Events.publish("payment.matched", {"matching_id" => "7", "sources" => "invoice:#{invoice.id}"})
    page = browser.get("/ext/CHORUSPRO/invoices/#{invoice.id}").html
    page.should contain("data-choruspro-settled")
    page.should contain(%(data-choruspro-status="paid"))
    page.should contain("Paiement lettré")
  end

  it "refuse les commandes sans le droit de déposer, et les paramètres sans le droit de les gérer" do
    S.books
    profile = PartiduoUi::Accounts.profile("Lecteur", [Choruspro::Api::READ, "invoicing.invoice.read"])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    reader = PartiduoUi::Accounts.signed_in("bob@example.com")
    invoice = S.issue
    reader.get("/ext/CHORUSPRO/").status.should eq(200)
    reader.post("/ext/CHORUSPRO/invoices/#{invoice.id}/transmit").status.should eq(403)
    reader.get("/ext/CHORUSPRO/settings").status.should eq(403)
  end
end
