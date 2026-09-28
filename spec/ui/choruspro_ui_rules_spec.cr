# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Écran Chorus Pro, cas limites : messages des refus du contrat, commandes
# offertes selon l'état de la facture et les droits, effacement des
# identifiants, extension désactivée.

private alias S = Choruspro::SpecSupport

private def signed_in : PartiduoUi::Browser
  S.books
  PartiduoUi::Accounts.signed_in
end

describe "Écran Chorus Pro — cas limites" do
  it "affiche les contrôles bloquants et refuse le dépôt avec leur message" do
    browser = signed_in
    S.connect
    invoice = S.issue(buyer_reference: nil, order_reference: nil)
    page = browser.get("/ext/CHORUSPRO/invoices/#{invoice.id}").html
    page.gsub("&#39;", "'").should contain("Ville de Paris exige un numéro d'engagement")
    page.should_not contain("data-choruspro-transmit")
    page.should_not contain("data-choruspro-manual")
    refused = browser.follow(browser.post("/ext/CHORUSPRO/invoices/#{invoice.id}/transmit")).html
    refused.should contain("exige un code service")
    S.chorus.deposits.should be_empty
  end

  it "ne propose ni dépôt, ni PDF, ni note pour un brouillon ; le dépôt forcé est refusé" do
    browser = signed_in
    S.connect
    draft = S.draft(S.public_customer)
    page = browser.get("/ext/CHORUSPRO/invoices/#{draft.id}").html
    page.should contain("Brouillon : émettez la facture avant de la déposer.")
    page.should_not contain("data-choruspro-transmit")
    page.should_not contain("data-choruspro-manual")
    page.should_not contain("/ext/CHORUSPRO/invoices/#{draft.id}/pdf")
    browser.follow(browser.post("/ext/CHORUSPRO/invoices/#{draft.id}/transmit")).html
      .should contain("Brouillon : émettez la facture avant de la déposer.")
    S.chorus.deposits.should be_empty
  end

  it "montre un dépôt sans réponse, propose de le noter ou de lever la réservation, puis de redéposer" do
    browser = signed_in
    S.connect
    invoice = S.issue
    S.chorus.lose_answer = true
    failed = browser.follow(browser.post("/ext/CHORUSPRO/invoices/#{invoice.id}/transmit")).html
    failed.gsub("&#39;", "'").should contain("Chorus Pro n'a pas répondu au dépôt")
    failed.should contain("data-choruspro-pending")
    failed.should contain("data-choruspro-release")
    failed.should contain("data-choruspro-manual")
    failed.should_not contain("data-choruspro-transmit")
    browser.get("/ext/CHORUSPRO/").html.should contain("data-choruspro-pending")
    released = browser.follow(browser.post("/ext/CHORUSPRO/invoices/#{invoice.id}/release")).html
    released.should contain("Réservation levée")
    released.should contain("data-choruspro-transmit")
    released.should_not contain("data-choruspro-pending")
  end

  it "traduit dans l'historique le motif d'un refus et le statut local, le statut brut à part" do
    browser = signed_in
    S.connect
    invoice = S.issue
    S.chorus.refusal = "Numéro en double"
    browser.post("/ext/CHORUSPRO/invoices/#{invoice.id}/transmit")
    S.chorus.refusal = nil
    browser.post("/ext/CHORUSPRO/invoices/#{invoice.id}/transmit")
    remote_id = (Choruspro::Submission.filter(invoice_id: invoice.id).first || raise "dépôt absent").remote_id.to_s
    S.chorus.advance(remote_id, "MISE_A_DISPOSITION")
    browser.post("/ext/CHORUSPRO/invoices/#{invoice.id}/refresh")
    page = browser.get("/ext/CHORUSPRO/invoices/#{invoice.id}").html
    page.should contain("Chorus Pro refuse la facture : Numéro en double")
    page.should contain("Mise à disposition")
    page.should contain("MISE_A_DISPOSITION")
    page.should_not contain("choruspro.errors")
  end

  it "rend le nombre de statuts relevés et les factures en erreur" do
    browser = signed_in
    S.connect
    lost = S.issue
    found = S.issue
    browser.post("/ext/CHORUSPRO/invoices/#{lost.id}/transmit")
    browser.post("/ext/CHORUSPRO/invoices/#{found.id}/transmit")
    rows = Choruspro::Submission.all.order(:id).to_a
    S.chorus.states.delete(rows[0].remote_id.to_s)
    S.chorus.advance(rows[1].remote_id.to_s, "MISE_A_DISPOSITION")
    page = browser.follow(browser.post("/ext/CHORUSPRO/refresh")).html
    page.should contain("1 statut changé.")
    page.should contain("#{lost.number} : Chorus Pro ne connaît pas cette facture.")
  end

  it "refuse un statut noté à la main sans motif, puis l'accepte avec son motif" do
    browser = signed_in
    Choruspro::Transports.current = nil
    invoice = S.issue
    browser.post("/ext/CHORUSPRO/invoices/#{invoice.id}/manual", {"remote_id" => "CPP-77"})
    page = browser.get("/ext/CHORUSPRO/invoices/#{invoice.id}").html
    page.should contain("data-choruspro-status-form")
    page.should_not contain("data-choruspro-manual")
    refused = browser.post("/ext/CHORUSPRO/invoices/#{invoice.id}/status", {"status" => "rejected", "reason" => "  "})
    browser.follow(refused).html.should contain("Indiquez le motif du rejet ou de la suspension.")
    accepted = browser.post("/ext/CHORUSPRO/invoices/#{invoice.id}/status", {"status" => "rejected", "reason" => "Doublon"})
    html = browser.follow(accepted).html
    html.should contain(%(data-choruspro-status="rejected"))
    html.should contain("Doublon")
    # Une commande appelée en GET renvoie à la fiche, sans rien changer.
    browser.get("/ext/CHORUSPRO/invoices/#{invoice.id}/status").status.should eq(302)
  end

  it "masque les commandes au lecteur et les identifiants à qui ne gère pas les paramètres" do
    S.books
    S.connect
    profile = PartiduoUi::Accounts.profile("Lecteur", [Choruspro::Api::READ, "invoicing.invoice.read"])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    reader = PartiduoUi::Accounts.signed_in("bob@example.com")
    invoice = S.issue
    page = reader.get("/ext/CHORUSPRO/invoices/#{invoice.id}").html
    page.should_not contain("data-choruspro-transmit")
    page.should_not contain("data-choruspro-manual")
    reader.get("/ext/CHORUSPRO/").html.should_not contain(Choruspro::SimulatedChorusPro::CLIENT_ID)
    reader.post("/ext/CHORUSPRO/invoices/#{invoice.id}/manual", {"remote_id" => "X"}).status.should eq(403)
    reader.post("/ext/CHORUSPRO/refresh").status.should eq(403)
    reader.post("/ext/CHORUSPRO/settings/clear").status.should eq(403)
    Choruspro::Api.settings(S.admin).secrets_stored.should be_true
  end

  it "efface les identifiants depuis les paramètres" do
    browser = signed_in
    S.connect
    cleared = browser.post("/ext/CHORUSPRO/settings/clear")
    browser.follow(cleared).status.should eq(200)
    Choruspro::Api.settings(S.admin).secrets_stored.should be_false
    browser.get("/ext/CHORUSPRO/").html.should contain("data-choruspro-unconfigured")
  end

  it "rend 404 sur toutes ses pages une fois l'extension désactivée" do
    browser = signed_in
    invoice = S.issue
    browser.get("/ext/CHORUSPRO/invoices/#{invoice.id}").status.should eq(200)
    Partiduo::Api::Modules.deactivate(S::SYSTEM, Choruspro::CODE).value!
    %w[/ext/CHORUSPRO/ /ext/CHORUSPRO/settings].each { |path| browser.get(path).status.should eq(404) }
    browser.get("/ext/CHORUSPRO/invoices/#{invoice.id}").status.should eq(404)
    browser.post("/ext/CHORUSPRO/invoices/#{invoice.id}/transmit").status.should eq(404)
  end
end
