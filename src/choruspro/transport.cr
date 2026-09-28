# SPDX-License-Identifier: AGPL-3.0-or-later

module Choruspro
  # Identifiants du dossier (déchiffrés le temps d'un appel, jamais
  # journalisés) : application du portail PISTE (`client_id`,
  # `client_secret`, OAuth 2 _client credentials_) et compte technique
  # Chorus Pro (`login`, `password`, en-tête `cpro-account`) ;
  # environnement `qualification` ou `production`.
  record Credentials, client_id : String, client_secret : String, login : String, password : String,
    env : String do
    def to_s(io : IO) : Nil
      io << "Choruspro::Credentials(" << client_id << ", ***, " << login << ", ***, " << env << ")"
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end
  end

  # Structure publique destinataire (`/cpro/structures/v1/consulter`) :
  # SIRET, raison sociale, gestion du numéro d'engagement et des services
  # (obligatoires ou non), codes des services actifs.
  record Structure, siret : String, name : String, engagement_required : Bool, service_required : Bool,
    services : Array(String)

  # Facture remise au transport : `reference` est la clé d'idempotence (un
  # même dépôt rejoué ne crée pas une seconde facture chez Chorus Pro),
  # `pdf` le PDF/A-3 Factur-X du module Facturation (engagement en BT-13,
  # code service en BT-10), syntaxe du flux `IN_DP_E2_CII_FACTURX`.
  record Deposit, reference : String, number : String, issue_date : Time, recipient_siret : String,
    service_code : String, engagement_number : String, total_gross : BigDecimal, currency : String,
    filename : String, pdf : Bytes

  # État d'une facture chez Chorus Pro : statut brut (`statutFacture`),
  # motif d'un rejet ou d'une suspension, date du dernier changement.
  record RemoteStatus, code : String, reason : String = "", at : Time? = nil

  # Erreur du transport : `key` est une clé i18n
  # (`choruspro.errors.transport.*`) traduite à l'affichage ; le message
  # technique ne contient jamais de secret.
  class TransportError < Exception
    getter key : String
    getter params : Hash(String, String)

    def initialize(@key : String, @params : Hash(String, String) = {} of String => String, message : String? = nil)
      super(message || @key)
    end
  end

  # Interface abstraite de Chorus Pro (ADR-004 D9 révisé) : l'extension est
  # écrite contre elle et testée contre un Chorus Pro simulé
  # (`spec/support/simulated_chorus_pro.cr`). L'adaptateur réel (PISTE,
  # `https://sandbox-api.piste.gouv.fr/cpro/…`) se branche par
  # `Choruspro::Transports.current =` quand les accès de qualification sont
  # obtenus (BLOCAGES B-FIN-002).
  abstract class Transport
    # Nom affiché (« Chorus Pro », « Chorus Pro simulé »).
    abstract def name : String

    # Vérifie les identifiants ; lève `TransportError`
    # (`choruspro.errors.transport.credentials`) s'ils sont refusés.
    abstract def check(credentials : Credentials) : Nil

    # Structure publique d'un SIRET, `nil` si Chorus Pro ne la connaît pas.
    abstract def structure(credentials : Credentials, siret : String) : Structure?

    # Dépose la facture ; rend son identifiant chez Chorus Pro. Idempotent
    # sur `deposit.reference`.
    abstract def submit(credentials : Credentials, deposit : Deposit) : String

    # Statut d'une facture déposée.
    abstract def status(credentials : Credentials, remote_id : String) : RemoteStatus
  end

  # Transport actif de l'instance. `nil` tant que l'adaptateur réel n'est
  # pas écrit : l'extension contrôle les factures, laisse télécharger le
  # PDF à déposer sur le portail Chorus Pro et noter le dépôt à la main
  # (repli, DECISIONS D-FIN-004).
  module Transports
    class_property current : Transport? = nil

    def self.available? : Bool
      !current.nil?
    end
  end
end
