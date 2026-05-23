# frozen_string_literal: true

# Doorkeeper access token (bearer token used by the MCP server). Subclassed
# so the row gets a UUID v7 id from ApplicationRecord's before_create
# callback (Doorkeeper's default model bypasses our AR base class).
#
# Referenced from config/initializers/doorkeeper.rb via `access_token_class`.
class Mcp::AccessToken < ApplicationRecord
  self.table_name = "oauth_access_tokens"

  include ::Doorkeeper::Orm::ActiveRecord::Mixins::AccessToken
end
