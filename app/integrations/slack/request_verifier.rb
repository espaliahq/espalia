# frozen_string_literal: true

# Verifies that an inbound HTTP request genuinely came from Slack, using the
# app signing secret. Slack signs every request (Events API, interactivity,
# slash commands) with an HMAC-SHA256 over "v0:{timestamp}:{raw_body}" and
# sends the result in the X-Slack-Signature header (prefixed "v0=") plus the
# timestamp in X-Slack-Request-Timestamp.
#
# See https://api.slack.com/authentication/verifying-requests-from-slack
#
# @example
#   Slack::RequestVerifier.valid?(
#     signature: request.headers["X-Slack-Signature"],
#     timestamp: request.headers["X-Slack-Request-Timestamp"],
#     body: request.raw_post,
#     secret: Slack.oauth_config[:signing_secret]
#   )
class Slack::RequestVerifier
  VERSION = "v0"
  # Reject anything older than this to blunt replay attacks (Slack's own
  # recommended window).
  MAX_SKEW_SECONDS = 60 * 5

  class << self
    # @param signature [String] the X-Slack-Signature header ("v0=…")
    # @param timestamp [String] the X-Slack-Request-Timestamp header (unix secs)
    # @param body [String] the raw, unparsed request body
    # @param secret [String] the app signing secret
    # @param now [Integer] current unix time (injectable for tests)
    # @return [Boolean]
    def valid?(signature:, timestamp:, body:, secret:, now: Time.now.to_i)
      return false if signature.blank? || timestamp.blank? || secret.blank?
      return false unless fresh?(timestamp, now)

      expected = sign(timestamp:, body:, secret:)
      ActiveSupport::SecurityUtils.secure_compare(expected, signature)
    end

    # @return [String] the "v0=…" signature for a given payload
    def sign(timestamp:, body:, secret:)
      basestring = "#{VERSION}:#{timestamp}:#{body}"
      "#{VERSION}=#{OpenSSL::HMAC.hexdigest('SHA256', secret, basestring)}"
    end

    private

    def fresh?(timestamp, now)
      (now - Integer(timestamp)).abs <= MAX_SKEW_SECONDS
    rescue ArgumentError, TypeError
      false
    end
  end
end
