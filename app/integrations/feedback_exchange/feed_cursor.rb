# frozen_string_literal: true

# The opaque position in the producer feed: the `(updated_at, id)` of the last
# row a page read. Encoded as URL-safe base64 of a small JSON array so a peer
# stores and returns it without parsing (protocol §5.1).
class FeedbackExchange::FeedCursor
  # A cursor the caller sent that does not decode to a position.
  class Invalid < StandardError; end

  # @return [Time] updated_at of the last row read
  attr_reader :updated_at
  # @return [String] id of the last row read
  attr_reader :id

  # @param updated_at [Time]
  # @param id [String]
  def initialize(updated_at:, id:)
    @updated_at = updated_at
    @id = id
  end

  # @param token [String, nil]
  # @return [FeedbackExchange::FeedCursor, nil] nil for an absent cursor
  # @raise [Invalid] when the token is not one this feed issued
  def self.decode(token)
    return nil if token.blank?

    timestamp, id = JSON.parse(Base64.urlsafe_decode64(token.to_s))
    raise Invalid, "cursor is malformed" unless timestamp.is_a?(String) && id.is_a?(String)
    raise Invalid, "cursor is malformed" unless timestamp.end_with?("Z")
    raise Invalid, "cursor is malformed" unless id.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)

    new(updated_at: Time.iso8601(timestamp).utc, id: id)
  rescue ArgumentError, JSON::ParserError, TypeError
    raise Invalid, "cursor is malformed"
  end

  # Microsecond precision, the column's own, so a row is never skipped or
  # repeated at a page boundary.
  #
  # @return [String]
  def encode
    Base64.urlsafe_encode64([ updated_at.utc.iso8601(6), id ].to_json, padding: false)
  end
end
