# frozen_string_literal: true

# Protocol records (feedback-exchange-protocol.md §4) for consumer tests,
# built from the shared fixture so the producer side can use the same one.
module FeedbackExchangeRecords
  RECORD_FIXTURE = Rails.root.join("test/fixtures/files/feedback_exchange/record.json")

  # @param overrides [Hash] top-level keys to replace, string or symbol
  # @return [Hash] a record with string keys
  def exchange_record(**overrides)
    JSON.parse(File.read(RECORD_FIXTURE)).merge(overrides.deep_stringify_keys)
  end

  # A tenant whose exchange with Chip is set up and switched on.
  def connect_feedback_exchange(tenant, **settings)
    tenant.update!(feedback_exchange_config: FeedbackExchangeConfig.new(
      peer_name: "chip", base_url: "https://chip.example.com/api/feedback-exchange", enabled: true, **settings
    ))
    tenant.update_feedback_exchange!(outbound_secret: SecureRandom.hex(32), inbound_secret: SecureRandom.hex(32))
  end
end
