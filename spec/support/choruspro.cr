# SPDX-License-Identifier: AGPL-3.0-or-later

module Choruspro
  module SpecSupport
    alias Api = Choruspro::Api
    alias Inv = Partiduo::Api::Invoicing
    alias Books = PartiduoUi::Books

    SYSTEM = Partiduo::Api::Actor.system
    ALL    = [Api::READ, Api::TRANSMIT, Api::SETTINGS, "invoicing.invoice.read"]
    @@admin_id = 1_i64

    def self.chorus : SimulatedChorusPro
      Transports.current.as(SimulatedChorusPro)
    end

    def self.admin(permissions : Array(String) = ALL) : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(@@admin_id, permissions, level: 3)
    end

    # Dossier français, administrateur, Chorus Pro actif.
    def self.books : Nil
      PartiduoUi::Reference.provision("fr")
      @@admin_id = PartiduoUi::Accounts.create.user.id
      Partiduo::Api::Modules.activate(SYSTEM, CODE).value!
      nil
    end

    def self.connect : Nil
      Api.save_credentials(SYSTEM, Api::CredentialsInput.new(SimulatedChorusPro::CLIENT_ID,
        SimulatedChorusPro::CLIENT_SECRET, SimulatedChorusPro::LOGIN, SimulatedChorusPro::PASSWORD)).value!
      nil
    end

    # Client public (nature « administration publique ») de SIRET donné.
    def self.public_customer(name : String = "Ville de Paris", siret : String? = SimulatedChorusPro::PARIS,
                             code : String? = nil, siren : String? = nil) : Partiduo::Api::Cards::CardView
      category = PartiduoUi::Reference.category("CUSTOMER")
      input = Partiduo::Api::Cards::CardInput.new(category_id: category.id, name: name, code: code, siret: siret, siren: siren,
        customer_nature: "public", email: "factures@public.test",
        address: Partiduo::Api::Cards::AddressInput.new(line1: "Place de l'Hôtel de Ville", postcode: "75004",
          city: "Paris", country_code: "FR"))
      Partiduo::Api::Cards.create_card(SYSTEM, input).value!
    end

    def self.item : Partiduo::Api::Cards::CardView
      Partiduo::Api::Cards.card_by_code(SYSTEM, "CONSEIL") || begin
        rate = Partiduo::Api::Vat.rate_by_code(SYSTEM, "NOR") || raise "taux NOR absent"
        Partiduo::Api::Cards.create_card(SYSTEM, Partiduo::Api::Cards::CardInput.new(
          category_id: PartiduoUi::Reference.category("SALE").id, name: "Conseil", code: "CONSEIL", unit_code: "HUR",
          sale_price: Books.d("80"), vat_rate_id: rate.id)).value!
      end
    end

    def self.draft(customer : Partiduo::Api::Cards::CardView, buyer_reference : String? = "FACTURES",
                   order_reference : String? = "EJ-2026-0042") : Inv::DocumentView
      Inv.create_document(SYSTEM, Inv::DocumentInput.new(kind: "invoice", customer_card_id: customer.id,
        lines: [Inv::LineInput.new(item_card_id: item.id, quantity: Books.d("10"))],
        buyer_reference: buyer_reference, order_reference: order_reference)).value!
    end

    def self.issue(customer : Partiduo::Api::Cards::CardView = public_customer, **options) : Inv::DocumentView
      Inv.issue(SYSTEM, draft(customer, **options).id, Inv::IssueInput.new(Books.date("2026-09-15"))).value!
    end
  end
end

# Chaque exemple part d'un Chorus Pro simulé vierge.
Spec.before_each do
  Choruspro::Transports.current = Choruspro::SimulatedChorusPro.new
end
