# SPDX-License-Identifier: AGPL-3.0-or-later

module Choruspro
  module Api
    # --- Entrées -----------------------------------------------------------------

    # Identifiants : application PISTE et compte technique. Un secret vide
    # garde celui enregistré.
    record CredentialsInput, client_id : String, client_secret : String, login : String, password : String,
      env : String = "qualification"

    # Dépôt fait sur le portail Chorus Pro, noté à la main (repli sans
    # transport) : numéro de la facture chez Chorus Pro, facultatif.
    record ManualInput, remote_id : String = ""

    # Statut noté à la main pour un dépôt fait sur le portail (`delivered`,
    # `paid`, `suspended`, `to_recycle`, `rejected` ; motif obligatoire pour
    # un rejet ou une suspension).
    record StatusInput, status : String, reason : String = ""

    # --- Vues --------------------------------------------------------------------

    # Contrôle d'une facture : clé i18n `choruspro.controls.*`, paramètres,
    # gravité `error` (bloque le dépôt) ou `warning`.
    record ControlView, key : String, params : Hash(String, String), severity : String do
      def error? : Bool
        severity == "error"
      end
    end

    record EventView, action : String, status : String, detail : String, user_id : Int64?, created_at : Time do
      def action_key : String
        "choruspro.actions.#{action}"
      end
    end

    # Dépôt d'une facture : statut local (`STATUSES`) et brut, identifiant
    # chez Chorus Pro, motif, historique ; `settled_at` : règlement complet
    # constaté par le lettrage (`payment.matched`).
    record SubmissionView,
      id : Int64,
      status : String,
      remote_id : String,
      remote_status : String,
      reason : String,
      manual : Bool,
      attempts : Int32,
      recipient_siret : String,
      service_code : String,
      engagement_number : String,
      submitted_at : Time,
      status_at : Time?,
      events : Array(EventView),
      settled_at : Time? = nil do
      def status_key : String
        "choruspro.statuses.#{status}"
      end

      def resubmittable? : Bool
        Config::RESUBMITTABLE.includes?(status)
      end
    end

    # Facture (ou avoir, acompte) au canal `public_portal`, brouillon ou émise,
    # avec son dépôt et ses contrôles. `service_code` = référence acheteur
    # (BT-10), `engagement_number` = référence de commande (BT-13) de la
    # facture ; `recipient_siret` = SIRET du client.
    record InvoiceView,
      id : Int64,
      kind : String,
      number : String?,
      issue_date : Time?,
      customer_name : String,
      recipient_siret : String,
      service_code : String,
      engagement_number : String,
      total_gross : BigDecimal,
      currency_code : String,
      sent_at : Time?,
      submission : SubmissionView?,
      controls : Array(ControlView) do
      def draft? : Bool
        number.nil?
      end

      def transmittable? : Bool
        !draft? && controls.none?(&.error?)
      end

      def kind_key : String
        "invoicing.kinds.#{kind}"
      end
    end

    # Paramètres : les secrets ne sont jamais rendus (`secrets_stored`) ;
    # l'identifiant de l'application et le compte technique ne le sont qu'aux
    # titulaires de `choruspro.settings.manage`.
    record SettingsView,
      env : String,
      client_id : String,
      login : String,
      secrets_stored : Bool,
      checked_at : Time?,
      transport : String?

    # Compteurs : factures émises à déposer, dépôts qui demandent une action
    # (rejet, suspension, à recycler).
    record CountsView, to_transmit : Int32, attention : Int32

    # Fichier produit (PDF à déposer sur le portail).
    record FileView, filename : String, content_type : String, content : Bytes
  end
end
