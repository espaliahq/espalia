# frozen_string_literal: true

FactoryBot.define do
  # `requester` / `requestee` are materialised (FK constraints + belongs_to
  # validations). `person_id` (the assessee) defaults to the requester so the
  # common "asking about my own assessment" shape needs no overrides — tests
  # for the manager-asking case override it. `framework_id` /
  # `capability_stable_id` are bare UUIDs, same convention as `evidence_items`.
  factory :evidence_request do
    association :tenant
    association :requester, factory: :person
    association :requestee, factory: :person
    person_id { requester.id }
    framework_id { SecureRandom.uuid_v7 }
    capability_stable_id { SecureRandom.uuid_v7 }
    level_ordinal { 3 }
    status { "pending" }
    requested_at { Time.current }
  end
end
