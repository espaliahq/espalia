# frozen_string_literal: true

# Error hierarchy for Slack Web API interactions.
#
# Used by {Slack::Client} and handled by the Slack notification delivery
# method (delivery is best-effort — failures are logged, not retried forever).
module Slack::Errors
  class Error < StandardError; end

  # Raised when the workspace token is missing/invalid/revoked
  # (Slack `invalid_auth`, `account_inactive`, `token_revoked`, `not_authed`).
  class AuthenticationError < Error; end

  # Raised on any other `ok: false` Slack response or transport failure.
  class ApiError < Error
    # @return [String, nil] the Slack error code (e.g. "channel_not_found")
    attr_reader :code

    # @param code [String, nil]
    def initialize(code: nil)
      @code = code
      super("Slack API error: #{code}")
    end
  end
end
