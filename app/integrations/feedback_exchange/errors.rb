# frozen_string_literal: true

# Error hierarchy for calls to a feedback exchange peer.
#
# Raised by {FeedbackExchange::Client}. The client never retries; the sync job
# decides what to retry or discard from the class.
module FeedbackExchange::Errors
  class Error < StandardError; end

  # Raised before any request when the peer's address points at the app's own
  # network or is not a plain host. The message is safe to show an admin.
  class AddressRefused < Error; end

  # Raised on HTTP 401: the peer rejected our signature. A human has to fix the secret.
  class AuthenticationError < Error; end

  # Raised on HTTP 429. Carries the peer's Retry-After when it sent one.
  class RateLimitError < Error
    # @return [Integer, nil] seconds to wait before retrying
    attr_reader :retry_after

    # @param retry_after [Integer, nil]
    def initialize(retry_after: nil)
      @retry_after = retry_after
      super("Rate limited. Retry after #{retry_after || '?'}s")
    end
  end

  # Raised on any other failure: 5xx, an unexpected 4xx, or no answer at all
  # (status nil).
  class ApiError < Error
    # @return [Integer, nil] HTTP status code, nil when the peer was unreachable
    attr_reader :status

    # @return [String, nil] response body, truncated
    attr_reader :body

    # @param status [Integer, nil]
    # @param body [String, nil]
    # @param message [String, nil] overrides the default message
    def initialize(status:, body: nil, message: nil)
      @status = status
      @body = body.to_s.truncate(500).presence
      super(message || "Feedback exchange peer error #{status}: #{@body}")
    end
  end
end
