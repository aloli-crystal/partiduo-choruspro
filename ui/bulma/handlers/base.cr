# SPDX-License-Identifier: AGPL-3.0-or-later

module Choruspro
  module Ui
    # Base des écrans de l'extension. L'accès a déjà été contrôlé par
    # `PartiduoUi::ExtensionHandler` à partir du manifeste ;
    # `Choruspro::Api` vérifie encore la permission de chaque commande.
    abstract class Handler < PartiduoUi::ScreenHandler
      alias Api = Choruspro::Api

      def messages(result) : String
        result.errors.map { |error| fmt.message(error) }.join(" ")
      end

      def crumbs(title : String? = nil) : Array(PartiduoUi::Screen::Crumb)
        list = [crumb("invoicing.menu.inv_documents"), crumb("choruspro.menu.invoices", title ? Ui.url("index") : nil)]
        list << PartiduoUi::Screen::Crumb.new(title) if title
        list
      end

      # Redirection vers la fiche d'une facture après une commande, avec le
      # message du résultat.
      def after(result, id : Int64, success_key : String) : Marten::HTTP::Response
        if result.success?
          flash["success"] = I18n.t(success_key)
        else
          flash["danger"] = messages(result)
        end
        go(Ui.url("invoice", id: id))
      end
    end
  end
end
