# SPDX-License-Identifier: AGPL-3.0-or-later

# Réaction aux paiements (`payment.matched`, `payment.unmatched`) : date du
# règlement complet de la facture constaté par le lettrage (`settled_at`),
# deux nouvelles actions d'historique (`payment`, `unpayment`). DECISIONS
# D-CPP-002.
class Migration::Choruspro::V0003 < Marten::Migration
  depends_on :choruspro, "0002_public_portal_dependency"

  def plan
    add_column :choruspro_submission, :settled_at, :date_time, null: true
    execute(
      "ALTER TABLE choruspro_submission_event DROP CONSTRAINT choruspro_submission_event_action_check",
      "ALTER TABLE choruspro_submission_event ADD CONSTRAINT choruspro_submission_event_action_check " \
      "CHECK (action IN ('submitted', 'status', 'manual', 'error'))"
    )
    execute(
      "ALTER TABLE choruspro_submission_event ADD CONSTRAINT choruspro_submission_event_action_check " \
      "CHECK (action IN ('submitted', 'status', 'manual', 'error', 'payment', 'unpayment'))",
      "ALTER TABLE choruspro_submission_event DROP CONSTRAINT choruspro_submission_event_action_check"
    )
  end
end
