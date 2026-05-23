# frozen_string_literal: true

FactoryBot.define do
  # `author` is materialised because of the FK + belongs_to validation.
  # `person_id` is intentionally a random UUID — the projection writes it
  # from PersonDevelopment event metadata, not from a live Person row.
  # Same convention as `evidence_items`/`assessment_level_ratings`.
  factory :person_development_comment do
    association :tenant
    association :author, factory: :person
    person_id { SecureRandom.uuid_v7 }
    framework_id { SecureRandom.uuid_v7 }
    commentable_type { PersonDevelopmentComment::ASSESSMENT_CELL }
    capability_stable_id { SecureRandom.uuid_v7 }
    level_ordinal { 3 }
    body { "Looks like solid evidence of this behaviour." }
    status { "active" }
    posted_at { Time.current }
  end
end
