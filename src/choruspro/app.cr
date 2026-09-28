# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./config"
require "./secrets"
require "./transport"
require "./piste"
require "./models/**"
require "./services/**"
require "./api/**"

# Extension Chorus Pro de Partiduo (ADR-004 D9 révisé, 28 septembre 2026) :
# les factures aux administrations publiques passent par Chorus Pro, pas par
# une plateforme agréée. Partiduo dépose le PDF/A-3 Factur-X du module
# Facturation (numéro d'engagement en BT-13, code service en BT-10) par l'API
# du portail PISTE, avec un compte technique, puis suit le statut de la
# facture (mise à disposition, rejet, suspension, mise en paiement). Même
# plan qu'une application du cœur (DECISIONS C1) ; `transport.cr` est
# l'interface abstraite, branchée sur une simulation dans les specs et sur
# le bac à sable de qualification quand les accès sont obtenus.
module Choruspro
  VERSION = "0.1.0"

  # Code du registre (ADR-003 D2) : `choruspro` dans `PARTIDUO_MODULES`.
  CODE = "CHORUSPRO"

  # Application Marten du métier : modèles (tables `choruspro_*`),
  # migrations et libellés.
  class App < Marten::App
    label "choruspro"
  end

  INSTALLED_APPS = [Choruspro::App] of Marten::Apps::Config.class
end

Choruspro::Transports.configure_from_env
Choruspro::Secrets.check_configuration
