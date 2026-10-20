# frozen_string_literal: true

# Error set shared by every AI adapter, so callers choose a retry policy from
# the class and never from an SDK's or a gateway's own exceptions.
module Ai::Errors
  class Error < StandardError; end

  # The endpoint rejected the key (401 or 403). A human has to fix it.
  class AuthenticationError < Error; end

  # 429. Carries the endpoint's Retry-After when it sent one.
  class RateLimitError < Error
    # @return [Integer, nil] seconds to wait before retrying
    attr_reader :retry_after

    # @param retry_after [Integer, nil]
    def initialize(retry_after: nil)
      @retry_after = retry_after
      super("Rate limited. Retry after #{retry_after || '?'}s")
    end
  end

  # Any other failure: 5xx, an unexpected 4xx, an answer that is not what the
  # protocol promises, or no answer at all (status nil).
  class ApiError < Error
    # @return [Integer, nil] HTTP status, nil when the endpoint was unreachable
    attr_reader :status

    # @return [String, nil] response body, truncated
    attr_reader :body

    # @param status [Integer, nil]
    # @param body [String, nil]
    # @param message [String, nil] overrides the default message
    def initialize(status:, body: nil, message: nil)
      @status = status
      @body = body.to_s.truncate(500).presence
      super(message || "Model endpoint error #{status}: #{@body}")
    end
  end

  # The saved config cannot be used as it stands, and retrying will not change
  # that: the address is on a private network. A human has to fix it.
  class ConfigurationError < Error; end

  # The model declined to answer. Not worth retrying: the same request is
  # declined again.
  class RefusalError < Error; end
end
