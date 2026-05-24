# frozen_string_literal: true

# Doorkeeper authorization-code grant. Subclassed so the row gets a UUID v7
# id from ApplicationRecord's before_create callback (Doorkeeper's default
# model bypasses our AR base class).
#
# Referenced from config/initializers/doorkeeper.rb via `access_grant_class`.
class Mcp::AccessGrant < ApplicationRecord
  self.table_name = "oauth_access_grants"

  include ::Doorkeeper::Orm::ActiveRecord::Mixins::AccessGrant
end
