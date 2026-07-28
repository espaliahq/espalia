# frozen_string_literal: true

FactoryBot.define do
  factory :calibration_session do
    tenant
    id { SecureRandom.uuid_v7 }
    cycle_id { SecureRandom.uuid_v7 }
    framework_id { SecureRandom.uuid_v7 }
    framework_version { 1 }
    sequence(:name) { |n| "Calibration ##{n}" }
    facilitator_id { SecureRandom.uuid_v7 }
    status { "draft" }

    trait :started do
      status { "started" }
      started_at { Time.current }
    end

    trait :closed do
      status { "closed" }
      close_reason { "facilitator" }
      closed_at { Time.current }
    end
  end

  factory :calibration_session_member do
    tenant
    association :session, factory: :calibration_session
    person_id { SecureRandom.uuid_v7 }
    member_type { "calibrant" }

    trait :participant do
      member_type { "participant" }
    end
  end
end
