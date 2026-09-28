# SPDX-License-Identifier: AGPL-3.0-or-later

module Choruspro
  module Ui
    # `/ext/CHORUSPRO/settings` : environnement, application PISTE et compte
    # technique ; les secrets ne sont jamais réaffichés.
    class SettingsHandler < Handler
      def get
        require_settings!
        show({} of String => Array(String))
      end

      def post
        require_settings!
        input = Api::CredentialsInput.new(client_id: field("client_id"), client_secret: field("client_secret"),
          login: field("login"), password: field("password", strip: false), env: field("env"))
        result = Api.save_credentials(current.actor, input)
        if result.success?
          flash["success"] = I18n.t("choruspro_ui.flash.credentials")
          return go(Ui.url("settings"))
        end
        show(errors_of(result), 422)
      end

      def show(errors : Hash(String, Array(String)), status : Int32 = 200) : Marten::HTTP::Response
        view = Api.settings(current.actor)
        page("choruspro/settings.html", {
          "title"        => I18n.t("choruspro_ui.settings.title"),
          "crumbs"       => [crumb("core.menu.settings"), PartiduoUi::Screen::Crumb.new(I18n.t("choruspro_ui.settings.title"))],
          "environments" => Api::ENVIRONMENTS.map { |code| Ui.row({"value" => code, "label" => I18n.t("choruspro.environments.#{code}"), "selected" => code == view.env ? "1" : nil}) },
          "settings"     => Ui.row({
            "client_id"      => view.client_id.presence,
            "login"          => view.login.presence,
            "secrets_stored" => view.secrets_stored ? "1" : nil,
            "checked_at"     => view.checked_at.try { |time| fmt.datetime(time) },
            "transport"      => view.transport,
            "env"            => I18n.t("choruspro.environments.#{view.env}"),
            "env_code"       => view.env,
          }),
          "errors" => Ui.row(errors.transform_values { |list| list.join(" ").as(String?) }),
        }, status: status)
      end

      private def require_settings! : Nil
        raise Partiduo::Api::Forbidden.new(Api::SETTINGS) unless can?(Api::SETTINGS)
      end
    end

    class ClearCredentialsHandler < SettingsHandler
      def get
        go(Ui.url("settings"))
      end

      def post
        Api.clear_credentials(current.actor)
        flash["success"] = I18n.t("choruspro_ui.flash.cleared")
        go(Ui.url("settings"))
      end
    end
  end
end
