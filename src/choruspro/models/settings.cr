# SPDX-License-Identifier: AGPL-3.0-or-later

module Choruspro
  # Paramètres de l'extension (ligne unique, `key = "default"`) :
  # environnement, application du portail PISTE et compte technique Chorus
  # Pro ; secrets *chiffrés* (`Choruspro::Secrets`). Interne.
  class Settings < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :key, :string, max_size: 16, unique: true, default: "default"
    field :env, :string, max_size: 16, default: "qualification"
    field :client_id, :string, max_size: 255, blank: true, default: ""
    # `v1:<base64>` : `{"client_secret": …, "password": …}` chiffré ; vide si aucun.
    field :secrets, :text, blank: true, default: ""
    field :login, :string, max_size: 255, blank: true, default: ""
    field :checked_at, :date_time, blank: true, null: true
    field :updated_by_id, :big_int, blank: true, null: true

    with_timestamp_fields

    def self.current : Settings?
      filter(key: "default").first
    end

    def self.current! : Settings
      current || new(key: "default")
    end
  end
end
