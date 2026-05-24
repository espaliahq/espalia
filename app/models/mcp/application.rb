# frozen_string_literal: true

# Doorkeeper OAuth application (== an MCP client registration) backed by
# our ApplicationRecord so the before_create UUID v7 callback applies.
# Doorkeeper's default model bypasses our AR base class — that's why we
# subclass here rather than using the gem default.
#
# Referenced from config/initializers/doorkeeper.rb via `application_class`.
class Mcp::Application < ApplicationRecord
  self.table_name = "oauth_applications"

  include ::Doorkeeper::Orm::ActiveRecord::Mixins::Application

  # Default inactivity window before a DCR-registered app is eligible
  # for pruning. The 1-hour token expiry means a real user re-authorises
  # the moment they need to act again, so 30 days is comfortably past
  # any reasonable abandonment of a CLI install.
  STALE_AFTER = 30.days

  scope :dynamically_registered, -> { where.not(dynamically_registered_at: nil) }

  # Apps registered via DCR whose most recent token issuance — or
  # registration time if no token was ever issued — is older than
  # `cutoff`. Joins out to oauth_access_tokens via a subselect so the
  # query stays on one round trip; cutoff is parameterised so the job
  # can override for ops/testing.
  scope :dcr_stale, ->(cutoff: STALE_AFTER.ago) {
    dynamically_registered
      .joins(<<~SQL)
        LEFT JOIN (
          SELECT application_id, MAX(created_at) AS last_token_at
          FROM oauth_access_tokens
          GROUP BY application_id
        ) AS t ON t.application_id = oauth_applications.id
      SQL
      .where(
        "COALESCE(t.last_token_at, oauth_applications.dynamically_registered_at) <= ?",
        cutoff
      )
  }
end
