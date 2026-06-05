# frozen_string_literal: true

FactoryBot.define do
  factory :recorded_reporting_manager do
    tenant
    person_id { SecureRandom.uuid_v7 }
    framework_id { SecureRandom.uuid_v7 }
    manager_id { SecureRandom.uuid_v7 }
    source { "hris" }
  end

  factory :manager_assessment_delegation do
    tenant
    person_id { SecureRandom.uuid_v7 }
    framework_id { SecureRandom.uuid_v7 }
    delegate_person_id { SecureRandom.uuid_v7 }
    granted_by_id { SecureRandom.uuid_v7 }
    status { "active" }
  end
end
