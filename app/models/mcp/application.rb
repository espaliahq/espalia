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
end
