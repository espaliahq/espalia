# frozen_string_literal: true

FactoryBot.define do
  factory :person_framework_assignment do
    tenant
    person_id { SecureRandom.uuid_v7 }
    framework_id { SecureRandom.uuid_v7 }
    role_id { SecureRandom.uuid_v7 }
    level_id { SecureRandom.uuid_v7 }
  end
end
