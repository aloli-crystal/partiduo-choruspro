# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension Chorus Pro (ADR-003 D2, ADR-004 D9 révisé).
#
# * Dépendance : `INVOICING` (factures au canal `public_portal`, PDF/A-3
#   Factur-X, « Marquer comme envoyé »).
# * Permissions : `choruspro.invoice.read` (voir les factures aux clients
#   publics et leur statut), `choruspro.invoice.transmit` (déposer sur
#   Chorus Pro, relever les statuts, noter un dépôt fait sur le portail),
#   `choruspro.settings.manage` (identifiants PISTE et compte technique).
# * Menus : « Chorus Pro » sous « Facturation » et paramètres sous
#   « Paramètres ».
# * Aucun abonnement : le canal se relit au dépôt (il reste modifiable
#   jusqu'à l'envoi, D-INV-016).
Partiduo::Modules.register do
  code "CHORUSPRO"
  name "choruspro.module.name"
  version "0.1.0"
  requires_core "~> 0.1"
  depends_on "INVOICING"

  permission "choruspro.invoice.read"
  permission "choruspro.invoice.transmit"
  permission "choruspro.settings.manage"

  menu "CHORUSPRO", parent: "BILLING", order: 60, route: "choruspro:index", permission: "choruspro.invoice.read",
    label: "choruspro.menu.invoices"
  menu "CHORUSPRO_SETTINGS", parent: "SETTINGS", order: 93, route: "choruspro:settings",
    permission: "choruspro.settings.manage", label: "choruspro.menu.settings"

  ui "bulma", path: "ui/bulma"
end
