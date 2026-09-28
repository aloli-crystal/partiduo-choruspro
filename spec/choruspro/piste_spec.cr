# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Adaptateur PISTE (D-CPP-001) contre un HTTP simulé : jeton OAuth 2,
# en-têtes, corps des requêtes tels que la documentation publique les
# décrit, lecture des réponses, erreurs ; aucun secret dans les messages.

private alias Piste = Choruspro::PisteTransport

private class FakeHttp < Choruspro::PisteTransport::Http
  record Sent, url : String, headers : HTTP::Headers, body : String

  getter sent = [] of Sent
  getter routes = {} of String => Array(Response)

  def on(suffix : String, status : Int32, body : String) : self
    (routes[suffix] ||= [] of Response) << Response.new(status, body)
    self
  end

  def post(url : String, headers : HTTP::Headers, body : String) : Response
    sent << Sent.new(url, headers, body)
    key = routes.keys.find { |suffix| url.ends_with?(suffix) } || raise "route inattendue : #{url}"
    queue = routes[key]
    queue.size > 1 ? queue.shift : queue.first
  end

  def calls(suffix : String) : Array(Sent)
    sent.select(&.url.ends_with?(suffix))
  end
end

private def credentials(env = "qualification") : Choruspro::Credentials
  Choruspro::Credentials.new("app-id", "app-secret-XYZ", "TECH_1@cpp.fr", "tech-password-XYZ", env)
end

private def token_ok(http : FakeHttp) : FakeHttp
  http.on("/api/oauth/token", 200, %({"access_token":"jeton-1","token_type":"Bearer","expires_in":3600}))
end

private def deposit : Choruspro::Deposit
  Choruspro::Deposit.new(reference: "PDUO-CPP-1-1", number: "F2026-0001", issue_date: Time.utc(2026, 9, 15),
    recipient_siret: "21750001600019", service_code: "FACTURES", engagement_number: "EJ-1",
    total_gross: BigDecimal.new("960.00"), currency: "EUR", filename: "F2026-0001.pdf", pdf: "%PDF-1.7 test".to_slice)
end

describe Choruspro::PisteTransport do
  it "obtient un jeton PISTE (client credentials) et le réutilise ; en-têtes Bearer et cpro-account" do
    http = token_ok(FakeHttp.new)
    http.on("structures/v1/rechercher", 200, %({"codeRetour":0,"listeStructures":[]}))
    transport = Piste.new(http)
    transport.structure(credentials, "21750001600019").should be_nil
    transport.structure(credentials, "21750001600019").should be_nil

    tokens = http.calls("/api/oauth/token")
    tokens.size.should eq(1)
    tokens.first.url.should eq("https://sandbox-oauth.piste.gouv.fr/api/oauth/token")
    form = URI::Params.parse(tokens.first.body)
    {form["grant_type"], form["client_id"], form["client_secret"], form["scope"]}
      .should eq({"client_credentials", "app-id", "app-secret-XYZ", "openid"})

    search = http.calls("structures/v1/rechercher").first
    search.url.should eq("https://sandbox-api.piste.gouv.fr/cpro/structures/v1/rechercher")
    search.headers["Authorization"].should eq("Bearer jeton-1")
    Base64.decode_string(search.headers["cpro-account"]).should eq("TECH_1@cpp.fr:tech-password-XYZ")
    JSON.parse(search.body).should eq(JSON.parse(%({"structure":{"identifiantStructure":"21750001600019","typeIdentifiantStructure":"SIRET"}})))
  end

  it "lit la structure : raison sociale, engagement et service exigés, services actifs" do
    http = token_ok(FakeHttp.new)
    http.on("structures/v1/rechercher", 200, %({"codeRetour":0,"listeStructures":[{"idStructureCPP":25461,"designationStructure":"VILLE DE PARIS"}]}))
    http.on("structures/v1/consulter", 200, %({"codeRetour":0,"raisonSociale":"Ville de Paris","parametres":{"numeroEJDoitEtreRenseigne":true,"codeServiceDoitEtreRenseigne":true}}))
    http.on("structures/v1/rechercher/services", 200, %({"codeRetour":0,"listeServices":[) +
                                                      %({"idService":1,"codeService":"FACTURES","estActif":true},) +
                                                      %({"idService":2,"codeService":"ANCIEN","estActif":false}]}))
    structure = Piste.new(http).structure(credentials("production"), "21750001600019") || raise "structure absente"
    structure.should eq(Choruspro::Structure.new("21750001600019", "Ville de Paris", true, true, ["FACTURES"]))
    JSON.parse(http.calls("structures/v1/consulter").first.body)["idStructureCPP"].should eq(25461)
    services = JSON.parse(http.calls("structures/v1/rechercher/services").first.body)
    services["idStructure"].should eq(25461)
    http.sent.first.url.should eq("https://oauth.piste.gouv.fr/api/oauth/token")
    http.sent.last.url.should start_with("https://api.piste.gouv.fr/cpro/")
  end

  it "dépose le Factur-X en flux et suit le flux jusqu'à la facture, puis son historique" do
    http = token_ok(FakeHttp.new)
    http.on("factures/v1/deposer/flux", 200, %({"codeRetour":0,"libelle":"GCU_MSG_01_000","numeroFluxDepot":"CPP1234567","dateDepot":"2026-09-28"}))
    transport = Piste.new(http)
    remote_id = transport.submit(credentials, deposit)
    remote_id.should eq("flux:CPP1234567")
    body = JSON.parse(http.calls("factures/v1/deposer/flux").first.body)
    {body["nomFichier"], body["syntaxeFlux"], body["avecSignature"]}.should eq({"F2026-0001.pdf", "IN_DP_E2_CII_FACTURX", false})
    Base64.decode_string(body["fichierFlux"].as_s).should eq("%PDF-1.7 test")

    http.on("transverses/v1/consulterCRDetaille", 200, %({"codeRetour":0,"etatCourantDepotFlux":"IN_EN_ATTENTE_TRAITEMENT"}))
    http.on("transverses/v1/consulterCRDetaille", 200, %({"codeRetour":0,"etatCourantDepotFlux":"IN_INTEGRE"}))
    http.on("factures/v1/rechercher/fournisseur", 200, %({"codeRetour":0,"listeFactures":[{"numeroFacture":"F2026-0001","identifiantFactureCPP":987654,"statut":"MISE_A_DISPOSITION"}]}))
    transport.status(credentials, remote_id).code.should eq("EN_COURS_ACHEMINEMENT")
    integrated = transport.status(credentials, remote_id)
    {integrated.code, integrated.remote_id}.should eq({"MISE_A_DISPOSITION", "987654"})
    JSON.parse(http.calls("factures/v1/rechercher/fournisseur").first.body)["numeroFluxDepot"].should eq("CPP1234567")

    http.on("factures/v1/consulter/historique", 200, %({"codeRetour":0,"idFacture":987654,"statutCourantCode":"MISE_EN_PAIEMENT"}))
    transport.status(credentials, "987654").code.should eq("MISE_EN_PAIEMENT")
    JSON.parse(http.calls("factures/v1/consulter/historique").first.body)["idFacture"].should eq(987654)
  end

  it "rend un flux rejeté avec son motif" do
    http = token_ok(FakeHttp.new)
    http.on("transverses/v1/consulterCRDetaille", 200, %({"codeRetour":0,"etatCourantDepotFlux":"IN_REJETE",) +
                                                       %("listeErreurDP":[{"numeroDP":"F2026-0001","libelleErreurDP":"Code service absent"}]}))
    status = Piste.new(http).status(credentials, "flux:CPP1")
    {status.code, status.reason}.should eq({"REJETEE", "Code service absent"})
  end

  it "rejoue une fois sur un 401 avec un nouveau jeton ; traduit les erreurs sans citer de secret" do
    http = FakeHttp.new
    http.on("/api/oauth/token", 200, %({"access_token":"jeton-1","expires_in":3600}))
    http.on("/api/oauth/token", 200, %({"access_token":"jeton-2","expires_in":3600}))
    http.on("structures/v1/rechercher", 401, "")
    http.on("structures/v1/rechercher", 200, %({"listeStructures":[]}))
    transport = Piste.new(http)
    transport.structure(credentials, "21750001600019").should be_nil
    http.calls("structures/v1/rechercher").map(&.headers["Authorization"]).should eq(["Bearer jeton-1", "Bearer jeton-2"])

    refused = FakeHttp.new.on("/api/oauth/token", 401, %({"error":"invalid_client"}))
    error = expect_raises(Choruspro::TransportError) { Piste.new(refused).check(credentials) }
    error.key.should eq("choruspro.errors.transport.credentials")

    rejected = token_ok(FakeHttp.new).on("factures/v1/deposer/flux", 200, %({"codeRetour":20001,"libelle":"Fichier invalide"}))
    error = expect_raises(Choruspro::TransportError) { Piste.new(rejected).submit(credentials, deposit) }
    {error.key, error.params}.should eq({"choruspro.errors.transport.refused", {"reason" => "Fichier invalide"}})

    down = token_ok(FakeHttp.new).on("structures/v1/rechercher", 503, "Service Unavailable")
    error = expect_raises(Choruspro::TransportError) { Piste.new(down).structure(credentials, "21750001600019") }
    error.key.should eq("choruspro.errors.transport.unavailable")

    [error.message.to_s, credentials.inspect].each do |text|
      text.should_not contain("app-secret-XYZ")
      text.should_not contain("tech-password-XYZ")
    end
  end

  it "n'est branché que sur demande de l'instance" do
    previous = ENV["PARTIDUO_CHORUSPRO_TRANSPORT"]?
    begin
      Choruspro::Transports.current = nil
      ENV.delete("PARTIDUO_CHORUSPRO_TRANSPORT")
      Choruspro::Transports.configure_from_env
      Choruspro::Transports.current.should be_nil
      ENV["PARTIDUO_CHORUSPRO_TRANSPORT"] = "piste"
      Choruspro::Transports.configure_from_env
      Choruspro::Transports.current.should be_a(Choruspro::PisteTransport)
    ensure
      previous ? (ENV["PARTIDUO_CHORUSPRO_TRANSPORT"] = previous) : ENV.delete("PARTIDUO_CHORUSPRO_TRANSPORT")
    end
  end
end
