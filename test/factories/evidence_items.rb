FactoryBot.define do
  factory :evidence_item do
    association :tenant
    association :author, factory: :person
    person_id { SecureRandom.uuid_v7 }
    framework_id { SecureRandom.uuid_v7 }
    capability_stable_id { SecureRandom.uuid_v7 }
    level_ordinal { 3 }
    source { "self" }
    evidence_type { "project_outcome" }
    content { "Shipped the migration project on time." }
    link_status { "active" }
    recorded_at { Time.current }
  end
end
