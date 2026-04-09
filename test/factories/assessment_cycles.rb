# frozen_string_literal: true

FactoryBot.define do
  factory :assessment_cycle do
    tenant
    cycle_id { SecureRandom.uuid_v7 }
    framework_id { SecureRandom.uuid_v7 }
    framework_version { 1 }
    sequence(:name) { |n| "Cycle ##{n}" }
    cycle_type { "regular" }
    status { "open" }
    opened_at { Time.current }

    trait :closed do
      status { "closed" }
      closed_at { Time.current }
    end
  end

  factory :assessment_cycle_participant do
    tenant
    association :cycle, factory: :assessment_cycle
    person_id { SecureRandom.uuid_v7 }
    status { "enrolled" }
    enrolled_at { Time.current }

    trait :started do
      status { "started" }
      started_at { Time.current }
    end

    trait :aligned do
      status { "aligned" }
      started_at { Time.current }
      aligned_at { Time.current }
    end

    trait :withdrawn do
      status { "withdrawn" }
      withdrawn_at { Time.current }
      withdrawal_reason { "manual" }
    end
  end
end
