# SPDX-License-Identifier: AGPL-3.0-or-later

# Réservation du dépôt et historique complet (relecture du lot K, DECISIONS
# D-CPP-005 à D-CPP-008) :
#
# * `choruspro_pending` : un dépôt par l'API en cours pour une facture
#   (unicité sur `invoice_id`), réservé *avant* l'appel à Chorus Pro ; état
#   `running` (appel en cours) ou `uncertain` (pas de réponse : issue
#   inconnue) ; `remote_id` : identifiant rendu par Chorus Pro quand
#   l'enregistrement local a échoué après un dépôt accepté ;
# * `choruspro_submission.settled_from` : statut du dépôt avant son passage à
#   `paid` par le lettrage, rétabli au délettrage ;
# * `choruspro_submission_event.remote_status` (statut brut de Chorus Pro,
#   `status` gardant le statut local) et `params` (paramètres JSON du motif,
#   clé i18n dans `detail`) ; nouvelles actions `uncertain` et `released`.
class Migration::Choruspro::V0004 < Marten::Migration
  depends_on :choruspro, "0003_settlement"

  def plan
    create_table :choruspro_pending do
      column :id, :big_int, primary_key: true, auto: true
      column :invoice_id, :big_int, unique: true
      column :reference, :string, max_size: 64
      column :state, :string, max_size: 16, default: "running"
      column :remote_id, :string, max_size: 128, default: ""
      column :user_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end
    execute(
      "ALTER TABLE choruspro_pending " \
      "ADD CONSTRAINT choruspro_pending_state_check CHECK (state IN ('running', 'uncertain')), " \
      "ADD CONSTRAINT choruspro_pending_invoice_fk FOREIGN KEY (invoice_id) REFERENCES invoicing_document (id)",
      "SELECT 1"
    )

    add_column :choruspro_submission, :settled_from, :string, max_size: 16, default: ""
    add_column :choruspro_submission_event, :remote_status, :string, max_size: 40, default: ""
    add_column :choruspro_submission_event, :params, :text, default: ""

    execute(
      "ALTER TABLE choruspro_submission_event DROP CONSTRAINT choruspro_submission_event_action_check",
      "ALTER TABLE choruspro_submission_event ADD CONSTRAINT choruspro_submission_event_action_check " \
      "CHECK (action IN ('submitted', 'status', 'manual', 'error', 'payment', 'unpayment'))"
    )
    execute(
      "ALTER TABLE choruspro_submission_event ADD CONSTRAINT choruspro_submission_event_action_check " \
      "CHECK (action IN ('submitted', 'status', 'manual', 'error', 'payment', 'unpayment', 'uncertain', 'released'))",
      "ALTER TABLE choruspro_submission_event DROP CONSTRAINT choruspro_submission_event_action_check"
    )
  end
end
