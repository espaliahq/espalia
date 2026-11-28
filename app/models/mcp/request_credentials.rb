# frozen_string_literal: true

# The credentials a request authenticated with, for the checks MCP grant and
# approval rows make under the account's lock before they are stored.
class Mcp::RequestCredentials < ActiveSupport::CurrentAttributes
  # Raised when the credentials a request authenticated with were replaced
  # before it stored a grant or an approval.
  class Replaced < StandardError; end

  # @return [String, nil] the account salt Devise keeps in the web session
  attribute :session_salt
  # @return [String, nil] the id of the access token an MCP call presented
  attribute :access_token_id
end
