# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Intégrité en base des tables de l'extension (migrations 0001 et 0003),
# vérifiée hors du contrat, par une connexion à part (chaque instruction
# refusée est annulée sans gêner la suite de l'exemple).

private alias S = Choruspro::SpecSupport
private alias Api = Choruspro::Api

private def raw(statement : String, *args) : Nil
  DB.connect(Partiduo::Config.database_url) do |db|
    db.exec("BEGIN")
    begin
      db.exec(statement, *args)
    rescue ex
      db.exec("ROLLBACK")
      raise ex
    end
    db.exec("COMMIT")
  end
end

private def scalar(statement : String, *args)
  Marten::DB::Connection.default.open(&.scalar(statement, *args))
end

# Facture déposée par le transport simulé : identifiant de son dépôt.
private def deposited : {Int64, Int64}
  S.books
  S.connect
  invoice = S.issue
  submission = Api.transmit(S.admin, invoice.id).value!.submission || raise "dépôt absent"
  {invoice.id, submission.id}
end

describe "Chorus Pro — intégrité en base" do
  it "contrôle le statut, le SIRET, l'identifiant chez Chorus Pro, le motif et le nombre d'essais" do
    _, id = deposited
    expect_raises(Exception, /choruspro_submission_status_check/) do
      raw("UPDATE choruspro_submission SET status = 'lost' WHERE id = $1", id)
    end
    expect_raises(Exception, /choruspro_submission_siret_check/) do
      raw("UPDATE choruspro_submission SET recipient_siret = '2175000160001A' WHERE id = $1", id)
    end
    expect_raises(Exception, /choruspro_submission_siret_check/) do
      raw("UPDATE choruspro_submission SET recipient_siret = '217500016' WHERE id = $1", id)
    end
    # Un dépôt par l'API a toujours son identifiant ; un dépôt noté à la main
    # peut s'en passer.
    expect_raises(Exception, /choruspro_submission_remote_check/) do
      raw("UPDATE choruspro_submission SET remote_id = '' WHERE id = $1", id)
    end
    raw("UPDATE choruspro_submission SET remote_id = '', manual = true WHERE id = $1", id)
    # Rejet ou suspension sans motif.
    %w[rejected suspended].each do |status|
      expect_raises(Exception, /choruspro_submission_reason_check/) do
        raw("UPDATE choruspro_submission SET status = $1, reason = '' WHERE id = $2", status, id)
      end
    end
    raw("UPDATE choruspro_submission SET status = 'rejected', reason = 'Doublon' WHERE id = $1", id)
    expect_raises(Exception, /choruspro_submission_attempts_check/) do
      raw("UPDATE choruspro_submission SET attempts = 0 WHERE id = $1", id)
    end
    scalar("SELECT status FROM choruspro_submission WHERE id = $1", id).should eq("rejected")
  end

  it "rattache le dépôt à une facture existante, une seule fois, et à un utilisateur existant" do
    invoice_id, id = deposited
    expect_raises(Exception, /choruspro_submission_invoice_fk/) do
      raw("UPDATE choruspro_submission SET invoice_id = 987654321 WHERE id = $1", id)
    end
    expect_raises(Exception, /choruspro_submission_user_fk/) do
      raw("UPDATE choruspro_submission SET submitted_by_id = 987654321 WHERE id = $1", id)
    end
    expect_raises(Exception, /unique|duplicate/i) do
      raw("INSERT INTO choruspro_submission (invoice_id, number, recipient_siret, remote_id, submitted_at, " \
          "created_at, updated_at) VALUES ($1, 'X', '21750001600019', 'CPP-2', now(), now(), now())", invoice_id)
    end
    # Une facture émise ne s'efface pas (garde du module Facturation) ; un
    # brouillon rattaché à un dépôt non plus (clé étrangère).
    expect_raises(Exception, /suppression interdite/) do
      raw("DELETE FROM invoicing_document WHERE id = $1", invoice_id)
    end
    draft = S.draft(S.public_customer)
    raw("INSERT INTO choruspro_submission (invoice_id, number, recipient_siret, manual, submitted_at, " \
        "created_at, updated_at) VALUES ($1, 'X', '21750001600019', true, now(), now(), now())", draft.id)
    expect_raises(Exception, /choruspro_submission_invoice_fk/) do
      raw("DELETE FROM invoicing_document WHERE id = $1", draft.id)
    end
  end

  it "garde les dépôts : suppression refusée même par une requête directe" do
    _, id = deposited
    expect_raises(Exception, /suppression interdite/) do
      raw("DELETE FROM choruspro_submission WHERE id = $1", id)
    end
    scalar("SELECT count(*) FROM choruspro_submission").should eq(1)
  end

  it "contrôle les actions de l'historique (paiement et délettrage compris) et ses rattachements" do
    invoice_id, id = deposited
    %w[submitted status manual error payment unpayment].each do |action|
      raw("INSERT INTO choruspro_submission_event (submission_id, invoice_id, action, created_at) " \
          "VALUES ($1, $2, $3, now())", id, invoice_id, action)
    end
    expect_raises(Exception, /choruspro_submission_event_action_check/) do
      raw("INSERT INTO choruspro_submission_event (submission_id, invoice_id, action, created_at) " \
          "VALUES ($1, $2, 'deleted', now())", id, invoice_id)
    end
    expect_raises(Exception, /choruspro_submission_event_submission_fk/) do
      raw("INSERT INTO choruspro_submission_event (submission_id, invoice_id, action, created_at) " \
          "VALUES (987654321, $1, 'status', now())", invoice_id)
    end
    expect_raises(Exception, /choruspro_submission_event_invoice_fk/) do
      raw("INSERT INTO choruspro_submission_event (submission_id, invoice_id, action, created_at) " \
          "VALUES (NULL, 987654321, 'error', now())")
    end
    # Une erreur avant tout dépôt n'a pas de dépôt.
    raw("INSERT INTO choruspro_submission_event (submission_id, invoice_id, action, created_at) " \
        "VALUES (NULL, $1, 'error', now())", invoice_id)
  end

  it "n'a qu'une ligne de paramètres, d'environnement connu" do
    S.books
    S.connect
    expect_raises(Exception, /choruspro_settings_key_check/) do
      raw("INSERT INTO choruspro_settings (key, created_at, updated_at) VALUES ('other', now(), now())")
    end
    expect_raises(Exception, /unique|duplicate/i) do
      raw("INSERT INTO choruspro_settings (key, created_at, updated_at) VALUES ('default', now(), now())")
    end
    expect_raises(Exception, /choruspro_settings_env_check/) do
      raw("UPDATE choruspro_settings SET env = 'sandbox'")
    end
    scalar("SELECT count(*) FROM choruspro_settings").should eq(1)
  end
end
