# frozen_string_literal: true

require "test_helper"

class FeedbackExchange::FeedCursorTest < ActiveSupport::TestCase
  should "round trip a position at microsecond precision" do
    at = Time.utc(2026, 10, 18, 3, 12, 44, 123_456)
    id = SecureRandom.uuid_v7

    decoded = FeedbackExchange::FeedCursor.decode(FeedbackExchange::FeedCursor.new(updated_at: at, id: id).encode)

    assert_equal at, decoded.updated_at
    assert_equal id, decoded.id
  end

  should "treat an absent token as the start" do
    assert_nil FeedbackExchange::FeedCursor.decode(nil)
    assert_nil FeedbackExchange::FeedCursor.decode("")
  end

  should "refuse a token that is not a position" do
    [ "!!", Base64.urlsafe_encode64("{}"), Base64.urlsafe_encode64("[1]"), Base64.urlsafe_encode64("nope") ].each do |token|
      assert_raises(FeedbackExchange::FeedCursor::Invalid) { FeedbackExchange::FeedCursor.decode(token) }
    end
  end
end
