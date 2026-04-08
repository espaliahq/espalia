# frozen_string_literal: true

# Custom error hierarchy for HiBob API interactions.
#
# Used by {Hris::Hibob::Client} and handled by {HrisSyncJob}
# for retry/discard decisions.
#
module Hris::Hibob::Errors
  class Error < StandardError; end

  # Raised on HTTP 401 — credentials are invalid, needs human intervention.
  class AuthenticationError < Error; end

  # Raised on HTTP 429 — rate limited by HiBob. Carries optional retry_after.
  class RateLimitError < Error
    # @return [Integer, nil] seconds to wait before retrying
    attr_reader :retry_after

    # @param retry_after [Integer, nil] seconds to wait before retrying
    def initialize(retry_after: nil)
      @retry_after = retry_after
      super("Rate limited. Retry after #{retry_after}s")
    end
  end

  # Raised on HTTP 4xx/5xx after retries exhausted.
  class ApiError < Error
    # @return [Integer, nil] HTTP status code
    attr_reader :status

    # @return [String, nil] response body
    attr_reader :body

    # @param status [Integer, nil] HTTP status code
    # @param body [String, nil] response body
    def initialize(status:, body:)
      @status = status
      @body = body
      super("HiBob API error #{status}: #{body}")
    end
  end
end
