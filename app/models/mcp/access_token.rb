# frozen_string_literal: true

# Doorkeeper access token (bearer token used by the MCP server). Subclassed
# so the row gets a UUID v7 id from ApplicationRecord's before_create
# callback (Doorkeeper's default model bypasses our AR base class).
#
# Referenced from config/initializers/doorkeeper.rb via `access_token_class`.
class Mcp::AccessToken < ApplicationRecord
  self.table_name = "oauth_access_tokens"

  include ::Doorkeeper::Orm::ActiveRecord::Mixins::AccessToken

  before_create :refuse_a_refresh_revoked_meanwhile, if: -> { previous_refresh_token.present? }

  private

  # Doorkeeper checks a refresh token's revocation on the row it loaded, without a
  # lock, so a credential change such as User#replace_credentials! or a password
  # reset can revoke it before this insert. Waiting on the lock those hold, then
  # reading the token again, puts the two in order.
  # Any stamp counts, as another process's clock may run ahead of this one. It also
  # refuses a refresh whose token a sibling refresh's first use revoked meanwhile;
  # that client signs in again.
  def refuse_a_refresh_revoked_meanwhile
    User.lock(User::CREDENTIALS_LOCK).find_by(id: resource_owner_id)
    # Uncached, so a read earlier in the request can't answer for the row after the lock.
    revoked = ActiveRecord::Base.uncached { self.class.where(refresh_token: previous_refresh_token).where.not(revoked_at: nil).exists? }
    raise Doorkeeper::Errors::InvalidGrantReuse if revoked
  end
end
