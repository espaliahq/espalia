# frozen_string_literal: true

FactoryBot.define do
  # `author` (the recorder of the evidence) is materialised because it has an
  # FK constraint and a belongs_to validation. `person_id` (the SUBJECT of the
  # evidence) is left as a random UUID — there is no FK on that column, by
  # design: the projection writes person_id from PersonDevelopment event
  # metadata, not from a live Person record. Same convention as
  # `assessment_level_ratings` / `person_framework_assignments` factories.
  # Tests that need person_id to reference a real Person can override.
  factory :evidence_item do
    transient do
      # In production the projection writes an active EvidenceLink for the
      # origin coordinate alongside the item. Mirror that so factory-built
      # items show up in the matrix / link-driven queries without each test
      # creating the link by hand. Set to false for the bare item row.
      with_link { true }
    end

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

    after(:create) do |item, evaluator|
      next unless evaluator.with_link
      next if item.link_status != "active"

      EvidenceLink.create!(
        tenant_id: item.tenant_id,
        evidence_id: item.id,
        person_id: item.person_id,
        framework_id: item.framework_id,
        capability_stable_id: item.capability_stable_id,
        level_ordinal: item.level_ordinal,
        link_status: "active",
        linked_by_id: item.author_id,
        linked_at: item.recorded_at
      )
    end
  end
end
