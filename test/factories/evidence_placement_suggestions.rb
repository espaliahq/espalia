# frozen_string_literal: true

FactoryBot.define do
  factory :evidence_placement_suggestion do
    transient do
      item { nil }
    end

    association :tenant
    evidence_id { item&.id || SecureRandom.uuid_v7 }
    person_id { item&.person_id || SecureRandom.uuid_v7 }
    framework_id { item&.framework_id || SecureRandom.uuid_v7 }
    capability_stable_id { SecureRandom.uuid_v7 }
    level_ordinal { 3 }
    valence { "demonstrated" }
    confidence { 0.8 }
    rationale { "“Led the incident review calmly” shows composure under pressure." }
    status { "pending" }
    provider { "anthropic" }
    model { "claude-opus-5-5" }
    prompt_version { "test" }
    generated_at { Time.current }
  end
end
