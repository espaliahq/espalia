# frozen_string_literal: true

# One row per request to publish a framework draft. Publishing runs in a
# background job (it migrates every assigned person's ratings, evidence and
# comments, which does not fit in a web request), so the request needs a
# durable record: it drives the "Publishing…" disabled state across reloads,
# blocks a second request while one is in flight (partial unique index), and
# keeps the outcome — including the failure message — for the review page and
# the requester's notification.
class CreateFrameworkPublications < ActiveRecord::Migration[8.1]
  def change
    create_table :framework_publications, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :framework_id, null: false
      t.integer :draft_version, null: false
      t.references :requested_by, type: :uuid, null: false, foreign_key: { to_table: :tenant_users }
      t.integer :status, null: false, default: 0
      t.integer :published_version
      t.text :error_message
      t.string :job_id
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :framework_publications, [ :framework_id, :created_at ]
    # status 0 = queued, 1 = running (see FrameworkPublication#status).
    add_index :framework_publications, :framework_id,
              unique: true, where: "status IN (0, 1)",
              name: "idx_framework_publications_one_in_flight"
  end
end
