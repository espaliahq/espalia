# frozen_string_literal: true

# Request signing for the feedback exchange (protocol §6).
#
# Every request carries `X-Exchange-Timestamp` (unix seconds) and
# `X-Exchange-Signature: v1=<hex>`, where the hex is an HMAC-SHA256 over
#
#   v1:<timestamp>:<METHOD>:<path_with_query>:<sha256_hex(raw_body)>
#
# Signing the method and path stops a captured GET being replayed as something
# else. Pure: no Rails beyond ActiveSupport, so the same code signs outgoing
# requests and verifies incoming ones. Replay claims are the caller's job (see
# {FeedbackExchangeSignedRequest}).
module FeedbackExchange::Signature
  VERSION = "v1"
  # A timestamp further than this from now is refused.
  MAX_SKEW = 5.minutes
  # How long the previous inbound secret still verifies after a rotation.
  ROTATION_WINDOW = 24.hours

  TIMESTAMP_HEADER = "X-Exchange-Timestamp"
  SIGNATURE_HEADER = "X-Exchange-Signature"
  CONSUMER_HEADER = "X-Exchange-Consumer"
  # Optional, outside the signature: names the secret that signed the request so
  # a verifier can load one tenant rather than try each.
  KEY_ID_HEADER = "X-Exchange-Key-Id"
  KEY_ID_FORMAT = /\A\h{16}\z/

  module_function

  # @param secret [String]
  # @return [String] the first 16 hex characters of the secret's SHA-256
  def key_id(secret)
    Digest::SHA256.hexdigest(secret.to_s)[0, 16]
  end

  # @param secret [String]
  # @param method [String, Symbol] HTTP method, any case
  # @param path_with_query [String] exactly as sent, e.g. "/api/x/feedback?limit=1"
  # @param body [String, nil] the raw bytes as sent; empty for a GET
  # @param timestamp [Integer, String] unix seconds
  # @return [String] the header value, "v1=<hex>"
  def sign(secret:, method:, path_with_query:, body:, timestamp:)
    "#{VERSION}=#{OpenSSL::HMAC.hexdigest('SHA256', secret, signing_string(method:, path_with_query:, body:, timestamp:))}"
  end

  # @param signature [String, nil] the X-Exchange-Signature header
  # @param timestamp [String, nil] the X-Exchange-Timestamp header
  # @param secret [String, nil] the current secret
  # @param previous_secret [String, nil] the secret before the last rotation
  # @param previous_rotated_at [Time, nil] when the rotation happened; the
  #   previous secret is accepted for {ROTATION_WINDOW} after it
  # @param now [Time] injectable for tests
  # @return [Boolean] whether the request is fresh and signed with an accepted secret
  def verify(signature:, timestamp:, secret:, method:, path_with_query:, body:,
             previous_secret: nil, previous_rotated_at: nil, now: Time.current)
    return false if signature.blank? || timestamp.blank?
    return false unless fresh?(timestamp, now)

    accepted = [ secret ]
    accepted << previous_secret if previous_rotated_at.present? && (now - previous_rotated_at) < ROTATION_WINDOW
    # Compare against every candidate, never short-circuiting on the first hit.
    accepted.compact_blank.map do |candidate|
      expected = sign(secret: candidate, method:, path_with_query:, body:, timestamp:)
      ActiveSupport::SecurityUtils.secure_compare(expected, signature.to_s)
    end.any?
  end

  # @return [String]
  def signing_string(method:, path_with_query:, body:, timestamp:)
    [ VERSION, timestamp, method.to_s.upcase, path_with_query, Digest::SHA256.hexdigest(body.to_s) ].join(":")
  end

  def fresh?(timestamp, now)
    (now.to_i - Integer(timestamp.to_s, 10)).abs <= MAX_SKEW
  rescue ArgumentError, TypeError
    false
  end
end
