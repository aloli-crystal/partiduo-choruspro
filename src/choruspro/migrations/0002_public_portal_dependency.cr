# SPDX-License-Identifier: AGPL-3.0-or-later

# L'extension ne dépose que les documents au canal `public_portal`, que crée
# la migration invoicing 0004 : cette migration, vide, en déclare la
# dépendance pour qu'une base migrée extension seule l'ait toujours. La
# migration 0001, qui a pu tourner, n'est pas modifiée (D-CPY-009 du cœur).
class Migration::Choruspro::V0002 < Marten::Migration
  depends_on :choruspro, "0001_create_choruspro"
  depends_on :invoicing, "0004_public_portal_channel"

  def plan
  end
end
