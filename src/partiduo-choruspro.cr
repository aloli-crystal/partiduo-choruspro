# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo-choruspro` : le métier de l'extension
# Chorus Pro (manifeste, dépôts, suivi des statuts, transport abstrait,
# contrat `Choruspro::Api`), sans interface. L'interface Bulma est dans
# `ui/bulma/`, requise à part par la distribution :
# `require "partiduo-choruspro/ui/bulma"`.
#
# La distribution ajoute ensuite `Choruspro::INSTALLED_APPS` à ses
# applications Marten, et `require "partiduo-choruspro/cli"` à sa ligne de
# commande (migrations).
require "partiduo"

require "./choruspro/app"
