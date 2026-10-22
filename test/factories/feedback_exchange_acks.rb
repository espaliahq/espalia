# frozen_string_literal: true

FactoryBot.define do
  factory :feedback_exchange_ack do
    association :tenant
    evidence_id { SecureRandom.uuid_v7 }
    consumer { "chip" }
    sequence(:remote_id) { |n| "chip-#{n}" }
    remote_url { "https://chip.example.com/feedback/#{remote_id}" }
  end
end
