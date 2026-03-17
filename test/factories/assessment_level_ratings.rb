# frozen_string_literal: true

FactoryBot.define do
  factory :assessment_level_rating do
    tenant
    person_id { SecureRandom.uuid_v7 }
    framework_id { SecureRandom.uuid_v7 }
    capability_stable_id { SecureRandom.uuid_v7 }
    level_ordinal { 3 }
    self_rated_frequency { nil }
    manager_rated_frequency { nil }
    aligned_frequency { nil }
  end
end
