# SPDX-License-Identifier: AGPL-3.0-or-later

module Choruspro
  # Chorus Pro simulé pour les specs (ADR-004 D9 révisé) : identifiants de
  # test, annuaire des structures publiques (engagement et service exigés
  # ou non), dépôts *non* idempotents (comme l'API de dépôt de flux : chaque
  # appel crée une facture), statuts programmés, pannes à la demande, dont
  # une réponse perdue après un dépôt accepté (`lose_answer`). Aucun appel
  # réseau.
  class SimulatedChorusPro < Transport
    CLIENT_ID     = "piste-app-test"
    CLIENT_SECRET = "secret-piste-0123456789"
    LOGIN         = "TECH_732829320@cpp2017.fr"
    PASSWORD      = "Mot-de-passe-technique-2026"

    # Ville de Paris : engagement et service exigés ; hôpital : ni l'un ni
    # l'autre.
    PARIS    = "21750001600019"
    HOSPITAL = "26440013600000"

    getter structures = {
      PARIS    => Structure.new(PARIS, "Ville de Paris", true, true, %w[FACTURES DSIN]),
      HOSPITAL => Structure.new(HOSPITAL, "CHU de Nantes", false, false, [] of String),
    }
    getter deposits = {} of String => Deposit
    getter remote_ids = {} of String => String
    getter states = {} of String => RemoteStatus
    property failure : String? = nil
    property refusal : String? = nil
    # Le prochain dépôt est accepté, mais la réponse se perd (délai dépassé).
    property? lose_answer = false
    # Appelé au début de chaque dépôt (dépôts simultanés dans les specs).
    property on_submit : Proc(Nil)? = nil
    getter calls = 0

    def name : String
      "Chorus Pro simulé"
    end

    def check(credentials : Credentials) : Nil
      @calls += 1
      raise TransportError.new("choruspro.errors.transport.unavailable") if failure
      unless credentials.client_id == CLIENT_ID && credentials.client_secret == CLIENT_SECRET &&
             credentials.login == LOGIN && credentials.password == PASSWORD
        raise TransportError.new("choruspro.errors.transport.credentials")
      end
    end

    def structure(credentials : Credentials, siret : String) : Structure?
      check(credentials)
      structures[siret]?
    end

    def submit(credentials : Credentials, deposit : Deposit) : String
      check(credentials)
      if reason = refusal
        raise TransportError.new("choruspro.errors.transport.refused", {"reason" => reason})
      end
      on_submit.try(&.call)
      remote_id = "CPP-#{100000 + deposits.size}"
      deposits[remote_id] = deposit
      remote_ids[deposit.reference] = remote_id
      states[remote_id] = RemoteStatus.new("DEPOSEE", at: Time.utc)
      if lose_answer?
        @lose_answer = false
        raise TransportError.new(TransportError::UNAVAILABLE, message: "délai dépassé")
      end
      remote_id
    end

    def status(credentials : Credentials, remote_id : String) : RemoteStatus
      check(credentials)
      states[remote_id]? || raise TransportError.new("choruspro.errors.transport.unknown_invoice")
    end

    # Fait avancer une facture chez Chorus Pro (côté destinataire) ;
    # `resolved` : identifiant définitif rendu au suivi (flux intégré), sous
    # lequel la facture est ensuite connue.
    def advance(remote_id : String, code : String, reason : String = "", resolved : String? = nil) : Nil
      states[remote_id] = RemoteStatus.new(code, reason, Time.utc, resolved)
      resolved.try { |id| states[id] = RemoteStatus.new(code, reason, Time.utc) }
    end
  end
end
