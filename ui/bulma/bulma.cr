# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension Chorus Pro (ADR-005 D4, ADR-004 D9 révisé) :
# écran « Chorus Pro » (factures au canal Chorus Pro, statut des dépôts),
# fiche d'une facture (contrôles, dépôt, statut, dépôt noté à la main,
# historique), paramètres (PISTE, compte technique). Montée par
# `partiduo-ui-bulma` sous `/ext/CHORUSPRO/` (ADR-003 D3). La distribution
# la requiert après l'interface :
#
# ```
# require "partiduo-ui-bulma/partiduo_ui"
# require "partiduo-choruspro"
# require "partiduo-choruspro/ui/bulma"
# ```
#
# puis ajoute `Choruspro::Ui::INSTALLED_APPS` à ses applications Marten.
# Ce dossier ne parle au métier que par `Choruspro::Api` et `Partiduo::Api`
# (vérifié par `spec/architecture/conventions_spec.cr`).
require "../../src/partiduo-choruspro"

require "./presenters"
require "./handlers/**"

module Choruspro
  module Ui
    # Application Marten de l'interface Bulma de l'extension : gabarits
    # (`templates/choruspro/`) et libellés d'écran (`locales/`, clés
    # `choruspro_ui.*`).
    class App < Marten::App
      label "choruspro_ui"
    end

    INSTALLED_APPS = [Choruspro::Ui::App] of Marten::Apps::Config.class

    # Routes servies sous `/ext/CHORUSPRO/`, nommées `choruspro:<nom>`.
    ROUTES = Marten::Routing::Map.draw do
      path "/", Choruspro::Ui::IndexHandler, name: "index"
      path "/refresh", Choruspro::Ui::RefreshAllHandler, name: "refresh_all"
      path "/invoices/<id:int>", Choruspro::Ui::InvoiceHandler, name: "invoice"
      path "/invoices/<id:int>/pdf", Choruspro::Ui::PdfHandler, name: "pdf"
      path "/invoices/<id:int>/transmit", Choruspro::Ui::TransmitHandler, name: "transmit"
      path "/invoices/<id:int>/refresh", Choruspro::Ui::RefreshHandler, name: "refresh"
      path "/invoices/<id:int>/manual", Choruspro::Ui::ManualHandler, name: "manual"
      path "/invoices/<id:int>/status", Choruspro::Ui::StatusHandler, name: "status"
      path "/invoices/<id:int>/release", Choruspro::Ui::ReleaseHandler, name: "release"
      path "/settings", Choruspro::Ui::SettingsHandler, name: "settings"
      path "/settings/clear", Choruspro::Ui::ClearCredentialsHandler, name: "clear_credentials"
    end
  end
end

# Toutes les routes exigent au moins `choruspro.invoice.read` ; le contrat
# vérifie ensuite la permission propre à chaque commande.
PartiduoUi::Extensions.mount Choruspro::CODE, Choruspro::Ui::ROUTES, permission: Choruspro::Api::READ
