FactoryBot.define do
  # `author` (the recorder of the evidence) is materialised because it has an
  # FK constraint and a belongs_to validation. `person_id` (the SUBJECT of the
  # evidence) is left as a random UUID — there is no FK on that column, by
  # design: the projection writes person_id from PersonDevelopment event
  # metadata, not from a live Person record. Same convention as
  # `assessment_level_ratings` / `person_framework_assignments` factories.
  # Tests that need person_id to reference a real Person can override.
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
