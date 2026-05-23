# frozen_string_literal: true

# Installs Doorkeeper's OAuth provider tables, adapted to the project's
# UUID v7 / `default: nil` PK convention (see rails-models.md). Also bakes
# in the `tenant_id` column on grants and tokens — tokens are bound to one
# tenant at consent time (see MCP design doc) so a user re-authorises to
# switch tenants. Shipping the column separately would mean an interim
# state where tokens have no tenant, which the MCP server cannot honour.
#
# Notes vs the generated migration:
# - `id: :uuid, default: nil` on all three tables to match the codebase
#   (IDs assigned in Ruby by ApplicationRecord's before_create callback).
# - `resource_owner_id` is `:uuid` with FK to `users`.
# - `application_id` is `:uuid` (matches the `:uuid` PK on `oauth_applications`).
# - `tenant_id` is `:uuid`, `null: false`, FK to `tenants`. The custom
#   Oauth::AuthorizationsController validates membership and rejects the
#   POST before it reaches strategy.authorize, so the grant is never
#   inserted without a tenant — and the access token inherits the same
#   tenant via Doorkeeper's custom_access_token_attributes plumbing.
# - PKCE columns (`code_challenge`, `code_challenge_method`) are added so
#   Doorkeeper's `force_pkce` enforcement has somewhere to write to.
class CreateDoorkeeperTables < ActiveRecord::Migration[8.1]
  def change
    create_table :oauth_applications, id: :uuid, default: nil do |t|
      t.string  :name,         null: false
      t.string  :uid,          null: false
      t.string  :secret,       null: false
      t.text    :redirect_uri, null: false
      t.string  :scopes,       null: false, default: ""
      t.boolean :confidential, null: false, default: true
      t.timestamps             null: false
    end
    add_index :oauth_applications, :uid, unique: true

    create_table :oauth_access_grants, id: :uuid, default: nil do |t|
      t.references :resource_owner, null: false, type: :uuid
      t.references :application,    null: false, type: :uuid
      t.references :tenant,         null: false, type: :uuid
      t.string   :token,             null: false
      t.integer  :expires_in,        null: false
      t.text     :redirect_uri,      null: false
      t.string   :scopes,            null: false, default: ""
      t.string   :code_challenge
      t.string   :code_challenge_method
      t.datetime :created_at,        null: false
      t.datetime :revoked_at
    end
    add_index :oauth_access_grants, :token, unique: true
    add_foreign_key :oauth_access_grants, :oauth_applications, column: :application_id
    add_foreign_key :oauth_access_grants, :users,              column: :resource_owner_id
    add_foreign_key :oauth_access_grants, :tenants,            column: :tenant_id

    create_table :oauth_access_tokens, id: :uuid, default: nil do |t|
      t.references :resource_owner, type: :uuid, index: true
      t.references :application,    null: false, type: :uuid
      t.references :tenant,         null: false, type: :uuid
      t.string   :token,                  null: false
      t.string   :refresh_token
      t.integer  :expires_in
      t.string   :scopes
      t.datetime :created_at, null: false
      t.datetime :revoked_at
      t.string   :previous_refresh_token, null: false, default: ""
    end
    add_index :oauth_access_tokens, :token, unique: true
    add_index :oauth_access_tokens, :refresh_token, unique: true
    add_foreign_key :oauth_access_tokens, :oauth_applications, column: :application_id
    add_foreign_key :oauth_access_tokens, :users,              column: :resource_owner_id
    add_foreign_key :oauth_access_tokens, :tenants,            column: :tenant_id
  end
end
