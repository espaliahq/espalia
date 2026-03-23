# frozen_string_literal: true

FactoryBot.define do
  factory :person_framework_assignment do
    tenant
    person_id { SecureRandom.uuid_v7 }
    framework_id { SecureRandom.uuid_v7 }
    role_id { SecureRandom.uuid_v7 }
    level_id { SecureRandom.uuid_v7 }
    cycle_status { "none" }

    trait :with_open_cycle do
      current_cycle_id { SecureRandom.uuid_v7 }
      cycle_status { "open" }
      cycle_name { "Q1 2026 Review" }
    end

    trait :completed do
      current_cycle_id { SecureRandom.uuid_v7 }
      cycle_status { "completed" }
      cycle_name { "Q1 2026 Review" }
    end
  end
end
