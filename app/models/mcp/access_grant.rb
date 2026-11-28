# frozen_string_literal: true

# Doorkeeper authorization-code grant. Subclassed so the row gets a UUID v7
# id from ApplicationRecord's before_create callback (Doorkeeper's default
# model bypasses our AR base class).
#
# Referenced from config/initializers/doorkeeper.rb via `access_grant_class`.
class Mcp::AccessGrant < ApplicationRecord
  self.table_name = "oauth_access_grants"

  include ::Doorkeeper::Orm::ActiveRecord::Mixins::AccessGrant

  before_create :refuse_a_grant_after_replaced_credentials

  private

  # A consent request is authenticated before it stores its grant, so a
  # credential change such as User#replace_credentials! or a password reset can
  # commit in between. Under the lock those take, the account's current salt
  # must still be the one the consenting session holds. With no salt set it
  # refuses, so any new path that stores a grant must set
  # Mcp::RequestCredentials first, as Oauth::AuthorizationsController does today.
  def refuse_a_grant_after_replaced_credentials
    account = User.lock(User::CREDENTIALS_LOCK).find_by(id: resource_owner_id)
    session_salt = Mcp::RequestCredentials.session_salt
    return if account && session_salt && account.authenticatable_salt == session_salt

    raise Mcp::RequestCredentials::Replaced
  end
end
