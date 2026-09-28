# SPDX-License-Identifier: AGPL-3.0-or-later

module Choruspro
  # Valeurs fermées de l'extension (vérifiées aussi en base par la
  # migration 0001).
  module Config
    # Statut d'un dépôt dans Partiduo :
    #
    # * `submitted` : déposé, accusé technique de Chorus Pro (`DEPOSEE`,
    #   `EN_COURS_ACHEMINEMENT`) ;
    # * `delivered` : mise à disposition du destinataire public
    #   (`MISE_A_DISPOSITION`, `SERVICE_FAIT`, `MANDATEE`, `COMPTABILISEE`…) ;
    # * `paid` : mise en paiement (`MISE_EN_PAIEMENT`) ;
    # * `suspended` : suspendue par le destinataire (`SUSPENDUE`) — à
    #   compléter sur le portail ;
    # * `to_recycle` : à recycler (`A_RECYCLER`) — mauvais destinataire ou
    #   service ; se recycle *sur le portail* Chorus Pro (nouveau service ou
    #   destinataire, sans nouveau dépôt), puis le statut se relève. Un
    #   redépôt du même PDF (même numéro, mêmes SIRET et BT-10) serait
    #   refusé comme doublon (D-CPP-006) ;
    # * `rejected` : rejetée (`REJETEE`), motif conservé ; la facture se
    #   corrige par un avoir.
    STATUSES = %w[submitted delivered paid suspended to_recycle rejected]

    # Statuts qui demandent une action (rejet, suspension, recyclage).
    ATTENTION = %w[rejected suspended to_recycle]

    # Correspondance des statuts de Chorus Pro (`statutFacture`).
    REMOTE_STATUSES = {
      "DEPOSEE"                      => "submitted",
      "EN_COURS_ACHEMINEMENT"        => "submitted",
      "MISE_A_DISPOSITION"           => "delivered",
      "SERVICE_FAIT"                 => "delivered",
      "MANDATEE"                     => "delivered",
      "MISE_A_DISPOSITION_COMPTABLE" => "delivered",
      "COMPTABILISEE"                => "delivered",
      "COMPLETEE"                    => "delivered",
      "MISE_EN_PAIEMENT"             => "paid",
      "SUSPENDUE"                    => "suspended",
      "A_RECYCLER"                   => "to_recycle",
      "REJETEE"                      => "rejected",
    }

    # Environnements de l'API : qualification (bac à sable) ou production.
    ENVIRONMENTS = %w[qualification production]

    # Cadre de facturation d'une facture de fournisseur (dépôt simple).
    BILLING_FRAMEWORK = "A1_FACTURE_FOURNISSEUR"

    def self.local_status(remote : String) : String?
      REMOTE_STATUSES[remote.upcase]?
    end
  end
end
