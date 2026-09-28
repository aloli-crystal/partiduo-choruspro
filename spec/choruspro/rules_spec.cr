# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Règles du contrat `Choruspro::Api` au-delà du parcours nominal :
# extension inactive ou sans sa dépendance, permissions de chaque commande,
# brouillons, dépôt noté à la main, relevé des statuts, identifiants et
# secrets, compteurs. (L'application d'origine n'a pas de Chorus Pro : les
# règles viennent de l'ADR-004 D9 révisé et de la documentation publique de
# Chorus Pro.)

private alias S = Choruspro::SpecSupport
private alias Api = Choruspro::Api
private alias Inv = Partiduo::Api::Invoicing
private alias Sim = Choruspro::SimulatedChorusPro

private def keys(result) : Array(String)
  result.errors.map(&.key)
end

private def submission_of(view : Api::InvoiceView) : Api::SubmissionView
  view.submission || raise "facture #{view.number} sans dépôt"
end

private def events_of(invoice_id : Int64) : Array(String)
  Choruspro::SubmissionEvent.filter(invoice_id: invoice_id).order(:id).map(&.action.to_s)
end

describe "Chorus Pro — règles du contrat" do
  describe "extension inactive" do
    it "lève ModuleDisabled sur chaque requête et commande" do
      S.books
      S.connect
      invoice = S.issue
      Partiduo::Api::Modules.deactivate(S::SYSTEM, Choruspro::CODE).value!
      actor = S.admin
      id = invoice.id
      calls = [
        -> { Api.settings(actor); nil },
        -> { Api.save_credentials(actor, Api::CredentialsInput.new("a", "b", "c", "d")); nil },
        -> { Api.clear_credentials(actor); nil },
        -> { Api.invoices(actor); nil },
        -> { Api.invoice(actor, id); nil },
        -> { Api.counts(actor); nil },
        -> { Api.pdf(actor, id); nil },
        -> { Api.transmit(actor, id); nil },
        -> { Api.refresh(actor, id); nil },
        -> { Api.refresh_all(actor); nil },
        -> { Api.note_manual(actor, id, Api::ManualInput.new); nil },
        -> { Api.note_status(actor, id, Api::StatusInput.new("paid")); nil },
        -> { Api.release(actor, id); nil },
      ]
      calls.each { |call| expect_raises(Partiduo::Api::ModuleDisabled) { call.call } }
      # Les données sont gardées ; rien n'est parti chez Chorus Pro.
      S.chorus.deposits.should be_empty
      Choruspro::Settings.current.should_not be_nil
      Partiduo::Api::Modules.activate(S::SYSTEM, Choruspro::CODE).value!
      Api.settings(actor).secrets_stored.should be_true
    end

    it "exige la Facturation active et la garde active tant qu'elle en dépend" do
      S.books
      refused = Partiduo::Api::Modules.deactivate(S::SYSTEM, "INVOICING")
      refused.success?.should be_false
      keys(refused).should eq(["modules.errors.activation.required_by"])
      refused.errors.first.params["dependent"].should eq(Choruspro::CODE)

      Partiduo::Api::Modules.deactivate(S::SYSTEM, Choruspro::CODE).value!
      Partiduo::Api::Modules.deactivate(S::SYSTEM, "INVOICING").value!
      missing = Partiduo::Api::Modules.activate(S::SYSTEM, Choruspro::CODE)
      keys(missing).should eq(["modules.errors.activation.missing_dependency"])
      missing.errors.first.params["dependency"].should eq("INVOICING")
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.invoices(S.admin) }
    end
  end

  describe "permissions" do
    it "réserve la lecture à choruspro.invoice.read" do
      S.books
      invoice = S.issue
      nobody = S.admin(["invoicing.invoice.read"])
      [
        -> { Api.settings(nobody); nil },
        -> { Api.invoices(nobody); nil },
        -> { Api.invoice(nobody, invoice.id); nil },
        -> { Api.counts(nobody); nil },
        -> { Api.pdf(nobody, invoice.id); nil },
      ].each { |call| expect_raises(Partiduo::Api::Forbidden) { call.call } }
      expect_raises(Partiduo::Api::Forbidden) { Api.invoices(Partiduo::Api::Actor.anonymous) }
    end

    it "réserve dépôt, relevé et notes à choruspro.invoice.transmit, identifiants à choruspro.settings.manage" do
      S.books
      S.connect
      invoice = S.issue
      reader = S.admin([Api::READ, Api::SETTINGS])
      [
        -> { Api.transmit(reader, invoice.id); nil },
        -> { Api.refresh(reader, invoice.id); nil },
        -> { Api.refresh_all(reader); nil },
        -> { Api.note_manual(reader, invoice.id, Api::ManualInput.new); nil },
        -> { Api.note_status(reader, invoice.id, Api::StatusInput.new("paid")); nil },
        -> { Api.release(reader, invoice.id); nil },
      ].each { |call| expect_raises(Partiduo::Api::Forbidden) { call.call } }
      depositor = S.admin([Api::READ, Api::TRANSMIT])
      expect_raises(Partiduo::Api::Forbidden) { Api.clear_credentials(depositor) }
      # Sans le droit de gérer : ni l'application PISTE ni le compte technique.
      view = Api.settings(depositor)
      {view.client_id, view.login, view.secrets_stored}.should eq({"", "", true})
      S.chorus.deposits.should be_empty
      Inv.document(S::SYSTEM, invoice.id).sent_at.should be_nil
    end
  end

  describe "dépôt" do
    it "refuse de déposer un brouillon, même complet, et n'appelle pas Chorus Pro" do
      S.books
      S.connect
      draft = S.draft(S.public_customer)
      keys(Api.transmit(S.admin, draft.id)).should eq(["choruspro.controls.draft"])
      S.chorus.deposits.should be_empty
      Choruspro::Submission.filter(invoice_id: draft.id).exists?.should be_false
      Api.invoice(S.admin, draft.id).transmittable?.should be_false
      keys(Api.note_manual(S.admin, draft.id, Api::ManualInput.new)).should eq(["choruspro.controls.draft"])
      expect_raises(Partiduo::Api::NotFound) { Api.pdf(S.admin, 987_654_321_i64) }
    end

    it "refuse une facture déjà envoyée autrement et ne propose pas le PDF d'un document hors canal" do
      S.books
      S.connect
      invoice = S.issue
      Inv.mark_sent(S::SYSTEM, invoice.id).value!
      keys(Api.transmit(S.admin, invoice.id)).should eq(["choruspro.controls.already_sent"])
      keys(Api.note_manual(S.admin, invoice.id, Api::ManualInput.new)).should eq(["choruspro.controls.already_sent"])
      S.chorus.deposits.should be_empty

      paper = Inv.issue(S::SYSTEM, Inv.create_document(S::SYSTEM, Inv::DocumentInput.new(kind: "invoice",
        customer_card_id: S.public_customer("Lycée", Sim::HOSPITAL).id,
        lines: [Inv::LineInput.new(item_card_id: S.item.id, quantity: S::Books.d("1"))],
        issue_channel: "paper")).value!.id, Inv::IssueInput.new(S::Books.date("2026-09-15"))).value!
      expect_raises(Partiduo::Api::NotFound) { Api.pdf(S.admin, paper.id) }
      Api.invoices(S.admin).map(&.id).should_not contain(paper.id)
      Api.counts(S.admin).to_transmit.should eq(0)
    end

    it "transmet au transport la facture telle qu'émise : montant à payer, devise, date, référence d'essai" do
      S.books
      S.connect
      invoice = S.issue
      remote_id = submission_of(Api.transmit(S.admin, invoice.id).value!).remote_id
      deposit = S.chorus.deposits[remote_id]
      document = Inv.document(S::SYSTEM, invoice.id)
      deposit.total_gross.should eq(document.totals.payable)
      deposit.total_gross.should be_a(BigDecimal)
      {deposit.currency, deposit.filename}.should eq({"EUR", "#{invoice.number}.pdf"})
      deposit.reference.should match(/\APDUO-CPP-#{invoice.id}-\d+\z/)
      Choruspro::Pending.all.exists?.should be_false
      deposit.issue_date.should eq(document.issue_date)
      events_of(invoice.id).should eq(["submitted"])
    end

    it "refuse le dépôt quand Chorus Pro ne répond pas au contrôle de la structure, puis laisse déposer" do
      S.books
      S.connect
      invoice = S.issue
      S.chorus.failure = "panne"
      keys(Api.transmit(S.admin, invoice.id)).should eq(["choruspro.errors.transport.unavailable"])
      Choruspro::Submission.filter(invoice_id: invoice.id).exists?.should be_false
      S.chorus.failure = nil
      submission_of(Api.transmit(S.admin, invoice.id).value!).attempts.should eq(1)
      # La panne survient au contrôle, avant tout dépôt : rien à l'historique.
      events_of(invoice.id).should eq(%w[submitted])
    end
  end

  describe "dépôt noté à la main" do
    it "contrôle l'identifiant, refuse un second dépôt et un statut sur un dépôt par l'API" do
      S.books
      Choruspro::Transports.current = nil
      invoice = S.issue
      keys(Api.note_status(S.admin, invoice.id, Api::StatusInput.new("paid"))).should eq(["choruspro.errors.status.no_submission"])
      too_long = Api.note_manual(S.admin, invoice.id, Api::ManualInput.new("X" * 129))
      keys(too_long).should eq(["choruspro.errors.manual.remote_id"])
      too_long.errors.first.field.should eq("remote_id")
      Inv.document(S::SYSTEM, invoice.id).sent_at.should be_nil

      noted = submission_of(Api.note_manual(S.admin, invoice.id, Api::ManualInput.new("   ")).value!)
      {noted.remote_id, noted.manual, noted.attempts}.should eq({"", true, 1})
      keys(Api.note_manual(S.admin, invoice.id, Api::ManualInput.new)).should eq(["choruspro.controls.already_submitted"])
      keys(Api.note_status(S.admin, invoice.id, Api::StatusInput.new("suspended", "   ")))
        .should eq(["choruspro.errors.status.reason"])
      keys(Api.note_status(S.admin, invoice.id, Api::StatusInput.new("submitted", ""))).should be_empty
      suspended = submission_of(Api.note_status(S.admin, invoice.id, Api::StatusInput.new("suspended", " Pièce manquante ")).value!)
      {suspended.status, suspended.reason}.should eq({"suspended", "Pièce manquante"})
      # Une mise en paiement efface le motif.
      submission_of(Api.note_status(S.admin, invoice.id, Api::StatusInput.new("paid")).value!).reason.should eq("")

      Choruspro::Transports.current = Sim.new
      S.connect
      other = S.issue
      Api.transmit(S.admin, other.id).value!
      keys(Api.note_status(S.admin, other.id, Api::StatusInput.new("paid"))).should eq(["choruspro.errors.status.not_manual"])
    end

    it "ne renote pas une facture « à recycler » : elle se recycle sur le portail, son statut se note" do
      S.books
      Choruspro::Transports.current = nil
      invoice = S.issue
      Api.note_manual(S.admin, invoice.id, Api::ManualInput.new("CPP-1")).value!
      Api.note_status(S.admin, invoice.id, Api::StatusInput.new("to_recycle")).value!
      Api.counts(S.admin).should eq(Api::CountsView.new(0, 1))
      keys(Api.note_manual(S.admin, invoice.id, Api::ManualInput.new("CPP-2"))).should eq(["choruspro.controls.recycle_on_portal"])
      again = submission_of(Api.note_status(S.admin, invoice.id, Api::StatusInput.new("delivered")).value!)
      {again.remote_id, again.status, again.attempts}.should eq({"CPP-1", "delivered", 1})
      Api.counts(S.admin).should eq(Api::CountsView.new(0, 0))
    end
  end

  describe "relevé des statuts" do
    it "garde le code de Chorus Pro comme motif d'un rejet sans motif, et le statut local d'un code inconnu" do
      S.books
      S.connect
      invoice = S.issue
      remote_id = submission_of(Api.transmit(S.admin, invoice.id).value!).remote_id
      S.chorus.advance(remote_id, "CODE_NOUVEAU")
      unknown = submission_of(Api.refresh(S.admin, invoice.id).value!)
      {unknown.status, unknown.remote_status}.should eq({"submitted", "CODE_NOUVEAU"})
      # Rien de neuf : pas de nouvelle ligne d'historique.
      Api.refresh(S.admin, invoice.id).value!
      events_of(invoice.id).should eq(%w[submitted status])
      S.chorus.advance(remote_id, "rejetee")
      rejected = submission_of(Api.refresh(S.admin, invoice.id).value!)
      {rejected.status, rejected.reason}.should eq({"rejected", "rejetee"})
      Api.counts(S.admin).attention.should eq(1)
      # Rejetée : se corrige par un avoir, pas par un nouveau dépôt.
      keys(Api.transmit(S.admin, invoice.id)).should eq(["choruspro.controls.already_submitted"])
    end

    it "arrête le relevé général quand Chorus Pro ne répond pas, la note, et saute les dépôts finis ou notés à la main" do
      S.books
      S.connect
      first = S.issue
      second = S.issue
      manual = S.issue
      done = S.issue
      a = submission_of(Api.transmit(S.admin, first.id).value!).remote_id
      b = submission_of(Api.transmit(S.admin, second.id).value!).remote_id
      Api.note_manual(S.admin, manual.id, Api::ManualInput.new("CPP-M")).value!
      d = submission_of(Api.transmit(S.admin, done.id).value!).remote_id
      S.chorus.advance(d, "REJETEE", "Doublon")
      Api.refresh(S.admin, done.id).value!
      S.chorus.advance(a, "MISE_A_DISPOSITION")
      S.chorus.advance(b, "MISE_A_DISPOSITION")
      S.chorus.advance(d, "MISE_EN_PAIEMENT")
      Api.refresh_all(S.admin).value!.changed.should eq(2)
      submission_of(Api.invoice(S.admin, done.id)).status.should eq("rejected")
      submission_of(Api.invoice(S.admin, manual.id)).status.should eq("submitted")

      S.chorus.failure = "panne"
      failed = Api.refresh_all(S.admin)
      keys(failed).should eq(["choruspro.errors.transport.unavailable"])
      events_of(first.id).last.should eq("error")
      keys(Api.refresh(S.admin, second.id)).should eq(["choruspro.errors.transport.unavailable"])
      Choruspro::Transports.current = nil
      keys(Api.refresh(S.admin, second.id)).should eq(["choruspro.controls.no_transport"])
    end
  end

  describe "identifiants" do
    it "contrôle la saisie et, sans transport, enregistre sans vérifier" do
      S.books
      Choruspro::Transports.current = nil
      invalid = Api.save_credentials(S.admin, Api::CredentialsInput.new(" ", "", "x" * 256, "", "sandbox"))
      keys(invalid).sort!.should eq(%w[choruspro.errors.credentials.client_id choruspro.errors.credentials.client_secret
        choruspro.errors.credentials.env choruspro.errors.credentials.login choruspro.errors.credentials.password])
      Choruspro::Settings.current.should be_nil
      saved = Api.save_credentials(S.admin, Api::CredentialsInput.new(" app ", " secret ", " login ", " mot de passe ")).value!
      {saved.client_id, saved.login, saved.checked_at, saved.transport, saved.env}
        .should eq({"app", "login", nil, nil, "qualification"})
      credentials = Choruspro::Deposits.credentials || raise "identifiants absents"
      # Le secret de l'application est nettoyé, le mot de passe gardé tel quel.
      {credentials.client_secret, credentials.password}.should eq({"secret", " mot de passe "})
      credentials.inspect.should_not contain("secret")
      credentials.to_s.should_not contain("mot de passe")
    end

    it "refuse des secrets illisibles (clé changée, valeur altérée) : dépôt impossible" do
      S.books
      S.connect
      invoice = S.issue
      row = Choruspro::Settings.current || raise "paramètres absents"
      value = row.secrets.to_s
      row.secrets = value[0, value.size - 4] + (value.ends_with?("AAAA") ? "BBBB" : "AAAA")
      row.save!
      Choruspro::Deposits.credentials.should be_nil
      keys(Api.transmit(S.admin, invoice.id)).should eq(["choruspro.controls.no_credentials"])
      keys(Api.save_credentials(S.admin, Api::CredentialsInput.new(Sim::CLIENT_ID, "", Sim::LOGIN, "")))
        .should contain("choruspro.errors.credentials.unreadable")
      # Nouveaux secrets saisis : la ligne est réparée.
      S.connect
      Api.transmit(S.admin, invoice.id).success?.should be_true
    end

    it "efface les identifiants : plus de dépôt possible" do
      S.books
      S.connect
      invoice = S.issue
      cleared = Api.clear_credentials(S.admin)
      {cleared.client_id, cleared.login, cleared.secrets_stored, cleared.checked_at}.should eq({"", "", false, nil})
      keys(Api.transmit(S.admin, invoice.id)).should eq(["choruspro.controls.no_credentials"])
      Api.invoice(S.admin, invoice.id).controls.map(&.key).should eq(["choruspro.controls.no_credentials"])
    end
  end

  describe "secrets" do
    it "chiffre avec un vecteur aléatoire, détecte l'altération et une autre clé" do
      Choruspro::Secrets.encrypt("").should eq("")
      Choruspro::Secrets.decrypt("").should eq("")
      one = Choruspro::Secrets.encrypt("mot de passe é")
      two = Choruspro::Secrets.encrypt("mot de passe é")
      one.should_not eq(two)
      one.should start_with("v1:")
      Choruspro::Secrets.decrypt(one).should eq("mot de passe é")
      expect_raises(Choruspro::Secrets::Error) { Choruspro::Secrets.decrypt("v2:" + one.lchop("v1:")) }
      expect_raises(Choruspro::Secrets::Error) { Choruspro::Secrets.decrypt("v1:AAAA") }
      expect_raises(Choruspro::Secrets::Error) { Choruspro::Secrets.decrypt("v1:@@@") }
      bytes = Base64.decode(one.lchop("v1:"))
      bytes[20] = bytes[20] ^ 1_u8
      expect_raises(Choruspro::Secrets::Error) { Choruspro::Secrets.decrypt("v1:" + Base64.strict_encode(bytes)) }

      previous = ENV["PARTIDUO_CHORUSPRO_KEY"]?
      begin
        ENV["PARTIDUO_CHORUSPRO_KEY"] = "ab" * 32
        expect_raises(Choruspro::Secrets::Error) { Choruspro::Secrets.decrypt(one) }
        Choruspro::Secrets.decrypt(Choruspro::Secrets.encrypt("x")).should eq("x")
      ensure
        previous ? (ENV["PARTIDUO_CHORUSPRO_KEY"] = previous) : ENV.delete("PARTIDUO_CHORUSPRO_KEY")
      end
    end
  end

  describe "correspondance des statuts" do
    it "range chaque code de Chorus Pro dans un statut local connu, sans tenir compte de la casse" do
      Choruspro::Config::REMOTE_STATUSES.values.uniq!.sort!.should eq(Choruspro::Config::STATUSES.sort)
      Choruspro::Config.local_status("mise_en_paiement").should eq("paid")
      Choruspro::Config.local_status("INCONNU").should be_nil
      Api::MANUAL_STATUS.should_not contain("submitted")
    end
  end
end
