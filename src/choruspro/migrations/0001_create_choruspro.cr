# SPDX-License-Identifier: AGPL-3.0-or-later

# Tables de l'extension Chorus Pro (ADR-004 D9 révisé) : paramètres
# (secrets chiffrés), dépôts et leur historique.
#
# Intégrité en base : une seule ligne de paramètres ; environnement et
# statuts contrôlés ; un dépôt porte le SIRET du destinataire (14 chiffres)
# et son identifiant chez Chorus Pro (sauf dépôt noté à la main) ; une
# facture rejetée ou suspendue a son motif ; la facture est un document du
# module Facturation (clé étrangère vers `invoicing_document`, canal
# `chorus_pro` de la migration invoicing 0003) ; un dépôt ne se supprime pas.
class Migration::Choruspro::V0001 < Marten::Migration
  depends_on :invoicing, "0003_customer_nature_pdf_copy"
  depends_on :auth, "0001_create_auth_user_table"

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE choruspro_settings
        ADD CONSTRAINT choruspro_settings_key_check CHECK (key = 'default'),
        ADD CONSTRAINT choruspro_settings_env_check CHECK (env IN ('qualification', 'production'))
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE choruspro_submission
        ADD CONSTRAINT choruspro_submission_status_check CHECK (status IN
          ('submitted', 'delivered', 'paid', 'suspended', 'to_recycle', 'rejected')),
        ADD CONSTRAINT choruspro_submission_siret_check CHECK (recipient_siret ~ '^[0-9]{14}$'),
        ADD CONSTRAINT choruspro_submission_remote_check CHECK (manual OR remote_id <> ''),
        ADD CONSTRAINT choruspro_submission_reason_check CHECK (status NOT IN ('rejected', 'suspended') OR reason <> ''),
        ADD CONSTRAINT choruspro_submission_attempts_check CHECK (attempts >= 1),
        ADD CONSTRAINT choruspro_submission_invoice_fk FOREIGN KEY (invoice_id) REFERENCES invoicing_document (id),
        ADD CONSTRAINT choruspro_submission_user_fk FOREIGN KEY (submitted_by_id) REFERENCES auth_user (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE choruspro_submission_event
        ADD CONSTRAINT choruspro_submission_event_action_check CHECK (action IN
          ('submitted', 'status', 'manual', 'error')),
        ADD CONSTRAINT choruspro_submission_event_submission_fk FOREIGN KEY (submission_id)
          REFERENCES choruspro_submission (id),
        ADD CONSTRAINT choruspro_submission_event_invoice_fk FOREIGN KEY (invoice_id) REFERENCES invoicing_document (id)
      SQL
    {<<-SQL, "DROP FUNCTION IF EXISTS choruspro_submission_guard() CASCADE"},
      CREATE FUNCTION choruspro_submission_guard() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'choruspro: dépôt de la facture % conservé, suppression interdite', OLD.number;
      END;
      $$ LANGUAGE plpgsql
      SQL
    {"CREATE TRIGGER choruspro_submission_guard BEFORE DELETE ON choruspro_submission " \
     "FOR EACH ROW EXECUTE FUNCTION choruspro_submission_guard()", "SELECT 1"},
  ]

  def plan
    create_table :choruspro_settings do
      column :id, :big_int, primary_key: true, auto: true
      column :key, :string, max_size: 16, unique: true, default: "default"
      column :env, :string, max_size: 16, default: "qualification"
      column :client_id, :string, max_size: 255, default: ""
      column :secrets, :text, default: ""
      column :login, :string, max_size: 255, default: ""
      column :checked_at, :date_time, null: true
      column :updated_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :choruspro_submission do
      column :id, :big_int, primary_key: true, auto: true
      column :invoice_id, :big_int, unique: true
      column :number, :string, max_size: 64
      column :recipient_siret, :string, max_size: 14
      column :service_code, :string, max_size: 100, default: ""
      column :engagement_number, :string, max_size: 100, default: ""
      column :status, :string, max_size: 16, default: "submitted"
      column :remote_id, :string, max_size: 128, default: ""
      column :remote_status, :string, max_size: 40, default: ""
      column :reason, :text, default: ""
      column :manual, :bool, default: false
      column :attempts, :int, default: 1
      column :submitted_at, :date_time
      column :submitted_by_id, :big_int, null: true
      column :status_at, :date_time, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :choruspro_submission_event do
      column :id, :big_int, primary_key: true, auto: true
      column :submission_id, :big_int, null: true, index: true
      column :invoice_id, :big_int, index: true
      column :action, :string, max_size: 16
      column :status, :string, max_size: 40, default: ""
      column :detail, :text, default: ""
      column :user_id, :big_int, null: true
      column :created_at, :date_time
    end

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
