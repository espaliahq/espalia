# frozen_string_literal: true

# The shared signing secrets for the feedback exchange, read from
# Tenant#feedback_exchange_credentials.
#
# Two secrets, one per direction: `outbound_secret` signs our requests to the
# peer, `inbound_secret` verifies theirs. Rotating the inbound secret keeps the
# old one as `previous_inbound_secret`; {FeedbackExchange::Signature.verify} honours it
# for {FeedbackExchange::Signature::ROTATION_WINDOW}.
#
# `inspect` and `to_s` never print a value, so an exception or a log line that
# captures the object cannot leak one.
class FeedbackExchangeSecrets
  KEYS = %w[outbound_secret inbound_secret previous_inbound_secret previous_rotated_at].freeze

  # @param raw [Hash, nil] the decoded credentials column
  def initialize(raw)
    @raw = raw.is_a?(Hash) ? raw.slice(*KEYS) : {}
  end

  # @return [String, nil] signs our requests to the peer
  def outbound_secret = @raw["outbound_secret"].presence

  # @return [String, nil] verifies the peer's requests to us
  def inbound_secret = @raw["inbound_secret"].presence

  # @return [String, nil] the inbound secret before the last rotation
  def previous_inbound_secret = @raw["previous_inbound_secret"].presence

  # @return [Time, nil] when the inbound secret was last rotated
  def previous_rotated_at
    value = @raw["previous_rotated_at"]
    value.present? ? Time.zone.parse(value.to_s) : nil
  end

  # @return [Boolean] both secrets present
  def complete? = outbound_secret.present? && inbound_secret.present?

  # @return [Hash{String => Boolean}] which values are set, for display
  def presence
    { "outbound_secret" => outbound_secret.present?, "inbound_secret" => inbound_secret.present? }
  end

  def inspect = "#<#{self.class.name} outbound=#{outbound_secret.present?} inbound=#{inbound_secret.present?}>"
  alias_method :to_s, :inspect
end
