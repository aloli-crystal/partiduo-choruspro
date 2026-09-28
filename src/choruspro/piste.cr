# SPDX-License-Identifier: AGPL-3.0-or-later

require "base64"
require "http/client"
require "json"
require "uri"

module Choruspro
  # Adaptateur réel de Chorus Pro par le portail PISTE (ADR-004 D9 révisé),
  # écrit d'après la documentation publique (communauté Chorus Pro, « Aide
  # aux développeurs API en mode OAuth2 ») et les appels du module libre
  # `l10n_fr_chorus_account` (OCA, AGPL). *Non essayé* sur la
  # qualification faute d'accès (BLOCAGES B-FIN-002) : il n'est branché que
  # si l'instance le demande (`PARTIDUO_CHORUSPRO_TRANSPORT=piste`,
  # DECISIONS D-CPP-001).
  #
  # * Jeton OAuth 2 PISTE, _client credentials_, portée `openid`, gardé en
  #   mémoire jusqu'à une minute de son échéance ; un refus 401 le jette et
  #   rejoue l'appel une fois.
  # * Chaque appel porte `Authorization: Bearer …` et `cpro-account:
  #   base64(login:mot de passe)` (compte technique).
  # * Structure : `structures/v1/rechercher` (SIRET) → `idStructureCPP` ;
  #   `structures/v1/consulter` (engagement, service exigés) ;
  #   `structures/v1/rechercher/services` (services actifs).
  # * Dépôt : `factures/v1/deposer/flux`, PDF/A-3 Factur-X en base 64,
  #   syntaxe `IN_DP_E2_CII_FACTURX` ; rend `flux:<numeroFluxDepot>`.
  # * Suivi : tant que l'identifiant est un flux,
  #   `transverses/v1/consulterCRDetaille` (flux rejeté → `REJETEE` avec
  #   le motif ; intégré → `factures/v1/rechercher/fournisseur` donne
  #   l'identifiant de la facture et son statut) ; ensuite
  #   `factures/v1/consulter/historique` (`statutCourantCode`).
  #
  # Aucun secret dans les messages d'erreur ni les journaux : les erreurs
  # portent une clé i18n, le code HTTP et le libellé de Chorus Pro.
  class PisteTransport < Transport
    # Échanges HTTP de l'adaptateur (POST seulement), remplaçables dans les
    # specs.
    abstract class Http
      record Response, status : Int32, body : String

      abstract def post(url : String, headers : HTTP::Headers, body : String) : Response
    end

    # HTTP réel : TLS vérifié, délais de 30 secondes. Ne suit pas
    # `HTTPS_PROXY` (comme le transport d'EINV, B-SPDP-001).
    class NetHttp < Http
      TIMEOUT = 30.seconds

      def post(url : String, headers : HTTP::Headers, body : String) : Response
        uri = URI.parse(url)
        raise TransportError.new("choruspro.errors.transport.unavailable", message: "adresse non HTTPS") unless uri.scheme == "https"
        client = HTTP::Client.new(uri)
        client.connect_timeout = TIMEOUT
        client.read_timeout = TIMEOUT
        begin
          response = client.post(uri.request_target, headers: headers, body: body)
          Response.new(response.status_code, response.body)
        ensure
          client.close
        end
      rescue ex : IO::Error | Socket::Error | OpenSSL::Error
        raise TransportError.new("choruspro.errors.transport.unavailable", message: "réseau : #{ex.class}")
      end
    end

    # Adresses par environnement.
    TOKEN_URLS = {
      "qualification" => "https://sandbox-oauth.piste.gouv.fr/api/oauth/token",
      "production"    => "https://oauth.piste.gouv.fr/api/oauth/token",
    }
    API_URLS = {
      "qualification" => "https://sandbox-api.piste.gouv.fr/cpro/",
      "production"    => "https://api.piste.gouv.fr/cpro/",
    }

    SYNTAX       = "IN_DP_E2_CII_FACTURX"
    FLUX_PREFIX  = "flux:"
    PAGE_SIZE    = 1000
    TOKEN_MARGIN = 60.seconds

    # États d'un flux déposé : rejeté, intégré (entièrement ou en partie).
    FLUX_REJECTED   = %w[IN_REJETE IN_INCIDENTE]
    FLUX_INTEGRATED = %w[IN_INTEGRE IN_INTEGRE_PARTIEL]

    record Token, value : String, expires_at : Time

    getter http : Http

    def initialize(@http : Http = NetHttp.new)
      @tokens = {} of String => Token
      @mutex = Mutex.new
    end

    def name : String
      "Chorus Pro (PISTE)"
    end

    # Jeton obtenu, puis un appel qui exige le compte technique.
    def check(credentials : Credentials) : Nil
      forget(credentials)
      call(credentials, "transverses/v1/recuperer/structures/actives/fournisseur", {} of String => String)
      nil
    end

    def structure(credentials : Credentials, siret : String) : Structure?
      found = call(credentials, "structures/v1/rechercher",
        {"structure" => {"identifiantStructure" => siret, "typeIdentifiantStructure" => "SIRET"}})
      first = found["listeStructures"]?.try(&.as_a?).try(&.first?)
      return unless first
      id = first["idStructureCPP"]
      detail = call(credentials, "structures/v1/consulter", {"idStructureCPP" => id, "codeLangue" => "fr"})
      params = detail["parametres"]? || JSON::Any.new({} of String => JSON::Any)
      name = string(detail["raisonSociale"]?).presence || string(first["designationStructure"]?).presence || siret
      Structure.new(siret, name, flag(params["numeroEJDoitEtreRenseigne"]?),
        flag(params["codeServiceDoitEtreRenseigne"]?), services(credentials, id))
    end

    def submit(credentials : Credentials, deposit : Deposit) : String
      answer = call(credentials, "factures/v1/deposer/flux", {
        "fichierFlux"   => Base64.strict_encode(deposit.pdf),
        "nomFichier"    => deposit.filename,
        "syntaxeFlux"   => SYNTAX,
        "avecSignature" => false,
      })
      number = string(answer["numeroFluxDepot"]?)
      if number.empty?
        raise TransportError.new("choruspro.errors.transport.refused", {"reason" => libelle(answer)})
      end
      FLUX_PREFIX + number
    end

    def status(credentials : Credentials, remote_id : String) : RemoteStatus
      if remote_id.starts_with?(FLUX_PREFIX)
        flux_status(credentials, remote_id.lchop(FLUX_PREFIX))
      else
        invoice_status(credentials, remote_id)
      end
    end

    # --- Suivi -------------------------------------------------------------------

    private def flux_status(credentials : Credentials, number : String) : RemoteStatus
      report = call(credentials, "transverses/v1/consulterCRDetaille", {"numeroFluxDepot" => number})
      state = string(report["etatCourantDepotFlux"]?)
      if FLUX_REJECTED.includes?(state)
        return RemoteStatus.new("REJETEE", flux_errors(report).presence || libelle(report).presence || state, Time.utc)
      end
      return RemoteStatus.new("EN_COURS_ACHEMINEMENT", at: Time.utc) unless FLUX_INTEGRATED.includes?(state)
      found = call(credentials, "factures/v1/rechercher/fournisseur",
        {"numeroFluxDepot" => number, "rechercheFactureParFournisseur" => {"nbResultatsParPage" => 10}})
      invoice = found["listeFactures"]?.try(&.as_a?).try(&.first?)
      return RemoteStatus.new("EN_COURS_ACHEMINEMENT", at: Time.utc) unless invoice
      id = string(invoice["identifiantFactureCPP"]?)
      RemoteStatus.new(string(invoice["statut"]?).presence || "DEPOSEE", at: Time.utc, remote_id: id.presence)
    end

    private def invoice_status(credentials : Credentials, remote_id : String) : RemoteStatus
      id = remote_id.to_i64? || raise TransportError.new("choruspro.errors.transport.unknown_invoice")
      answer = call(credentials, "factures/v1/consulter/historique", {"idFacture" => id})
      code = string(answer["statutCourantCode"]?)
      raise TransportError.new("choruspro.errors.transport.unknown_invoice") if code.empty?
      RemoteStatus.new(code, at: Time.utc)
    end

    private def flux_errors(report : JSON::Any) : String
      messages = [] of String
      report["listeErreurDP"]?.try(&.as_a?).try &.each do |error|
        messages << string(error["libelleErreurDP"]?)
      end
      report["listeErreurTechnique"]?.try(&.as_a?).try &.each do |error|
        messages << string(error["libelleErreur"]?)
      end
      messages.reject(&.empty?).uniq!.join(" ; ")
    end

    private def services(credentials : Credentials, id : JSON::Any) : Array(String)
      answer = call(credentials, "structures/v1/rechercher/services",
        {"idStructure" => id, "parametresRechercherServicesStructure" => {"nbResultatsParPage" => PAGE_SIZE}})
      list = answer["listeServices"]?.try(&.as_a?) || [] of JSON::Any
      list.select { |service| service["estActif"]?.try(&.as_bool?) != false }
        .map { |service| string(service["codeService"]?) }.reject(&.empty?)
    end

    # --- Échanges ------------------------------------------------------------------

    # POST JSON authentifié ; `codeRetour` non nul → refus de Chorus Pro.
    private def call(credentials : Credentials, path : String, payload) : JSON::Any
      body = payload.to_json
      response = send(credentials, path, body)
      if response.status == 401
        forget(credentials)
        response = send(credentials, path, body)
      end
      answer = parse(response)
      code = answer["codeRetour"]?.try { |value| value.as_i64? || value.as_s?.try(&.to_i64?) }
      if code && code != 0
        raise TransportError.new("choruspro.errors.transport.refused", {"reason" => libelle(answer).presence || code.to_s})
      end
      answer
    end

    private def send(credentials : Credentials, path : String, body : String) : Http::Response
      headers = HTTP::Headers{
        "Authorization" => "Bearer #{token(credentials)}",
        "cpro-account"  => Base64.strict_encode("#{credentials.login}:#{credentials.password}"),
        "Content-Type"  => "application/json;charset=utf-8",
        "Accept"        => "application/json",
      }
      http.post(api_url(credentials) + path, headers, body)
    end

    private def parse(response : Http::Response) : JSON::Any
      case response.status
      when 200..299
        response.body.strip.empty? ? JSON::Any.new({} of String => JSON::Any) : JSON.parse(response.body)
      when 401, 403
        raise TransportError.new("choruspro.errors.transport.credentials", message: "HTTP #{response.status}")
      when 400, 404, 422
        answer = JSON.parse(response.body) rescue JSON::Any.new({} of String => JSON::Any)
        raise TransportError.new("choruspro.errors.transport.refused",
          {"reason" => libelle(answer).presence || "HTTP #{response.status}"}, "HTTP #{response.status}")
      else
        raise TransportError.new("choruspro.errors.transport.unavailable", message: "HTTP #{response.status}")
      end
    rescue JSON::ParseException
      raise TransportError.new("choruspro.errors.transport.unavailable", message: "réponse illisible")
    end

    # --- Jeton PISTE -----------------------------------------------------------------

    private def token(credentials : Credentials) : String
      key = token_key(credentials)
      @mutex.synchronize do
        current = @tokens[key]?
        return current.value if current && current.expires_at - TOKEN_MARGIN > Time.utc
      end
      form = URI::Params.encode({"grant_type" => "client_credentials", "client_id" => credentials.client_id,
                                 "client_secret" => credentials.client_secret, "scope" => "openid"})
      headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded", "Accept" => "application/json"}
      response = http.post(TOKEN_URLS[credentials.env]? || TOKEN_URLS["qualification"], headers, form)
      if response.status.in?(400, 401, 403)
        raise TransportError.new("choruspro.errors.transport.credentials", message: "jeton PISTE : HTTP #{response.status}")
      end
      answer = parse(response)
      value = string(answer["access_token"]?)
      raise TransportError.new("choruspro.errors.transport.credentials", message: "jeton PISTE absent") if value.empty?
      lifetime = answer["expires_in"]?.try { |item| item.as_i64? || item.as_s?.try(&.to_i64?) } || 3600_i64
      @mutex.synchronize { @tokens[key] = Token.new(value, Time.utc + lifetime.seconds) }
      value
    end

    private def forget(credentials : Credentials) : Nil
      @mutex.synchronize { @tokens.delete(token_key(credentials)) }
    end

    # Le secret n'entre pas dans la clé ; un secret changé passe par
    # `check`, qui oublie le jeton.
    private def token_key(credentials : Credentials) : String
      "#{credentials.env}|#{credentials.client_id}"
    end

    private def api_url(credentials : Credentials) : String
      API_URLS[credentials.env]? || API_URLS["qualification"]
    end

    # --- Lecture ---------------------------------------------------------------------

    private def string(value : JSON::Any?) : String
      return "" unless value
      value.as_s? || value.raw.to_s
    end

    private def flag(value : JSON::Any?) : Bool
      return false unless value
      value.as_bool? || value.as_s?.try(&.downcase.in?("true", "oui", "1")) || false
    end

    private def libelle(answer : JSON::Any) : String
      string(answer["libelle"]?).presence || string(answer["message"]?)
    end
  end
end
