# SPDX-License-Identifier: AGPL-3.0-or-later

module Choruspro
  # Dépôt d'une facture sur Chorus Pro (une ligne par facture, document du
  # module Facturation `invoice_id`) : destinataire (SIRET), code service et
  # numéro d'engagement lus sur la facture au dépôt, identifiant chez Chorus
  # Pro (`remote_id`), statut local (`Config::STATUSES`) et statut brut
  # (`remote_status`), motif d'un rejet ou d'une suspension. `manual` : dépôt
  # fait sur le portail et noté à la main. Interne.
  class Submission < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :invoice_id, :big_int, unique: true
    field :number, :string, max_size: 64
    field :recipient_siret, :string, max_size: 14
    field :service_code, :string, max_size: 100, blank: true, default: ""
    field :engagement_number, :string, max_size: 100, blank: true, default: ""
    field :status, :string, max_size: 16, default: "submitted"
    field :remote_id, :string, max_size: 128, blank: true, default: ""
    field :remote_status, :string, max_size: 40, blank: true, default: ""
    field :reason, :text, blank: true, default: ""
    field :manual, :bool, default: false
    field :attempts, :int, default: 1
    field :submitted_at, :date_time
    field :submitted_by_id, :big_int, blank: true, null: true
    field :status_at, :date_time, blank: true, null: true

    with_timestamp_fields
  end

  # Historique d'un dépôt : dépôt, changement de statut, erreur du
  # transport, avec son auteur. Interne.
  class SubmissionEvent < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :submission_id, :big_int, blank: true, null: true, index: true
    field :invoice_id, :big_int, index: true
    field :action, :string, max_size: 16
    field :status, :string, max_size: 40, blank: true, default: ""
    field :detail, :text, blank: true, default: ""
    field :user_id, :big_int, blank: true, null: true
    field :created_at, :date_time
  end
end
