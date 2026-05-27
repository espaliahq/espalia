# frozen_string_literal: true

FactoryBot.define do
  factory :assessment_cycle do
    tenant
    cycle_id { SecureRandom.uuid_v7 }
    framework_id { SecureRandom.uuid_v7 }
    framework_version { 1 }
    latest_framework_version { framework_version }
    sequence(:name) { |n| "Cycle ##{n}" }
    cycle_type { "regular" }
    status { "open" }
    opened_at { Time.current }

    trait :closed do
      status { "closed" }
      closed_at { Time.current }
    end
  end

  factory :assessment_cycle_enrollment do
    tenant
    association :cycle, factory: :assessment_cycle
    person_id { SecureRandom.uuid_v7 }
    status { "enrolled" }
    enrolled_at { Time.current }

    trait :withdrawn do
      status { "withdrawn" }
      withdrawn_at { Time.current }
      withdrawal_reason { "manual" }
    end
  end

  factory :assessment_cycle_progress, class: "AssessmentCycleProgress" do
    tenant
    association :cycle, factory: :assessment_cycle
    person_id { SecureRandom.uuid_v7 }
    status { "in_progress" }

    trait :started do
      status { "started" }
      started_at { Time.current }
    end

    trait :aligning do
      status { "aligning" }
      started_at { 1.day.ago }
      alignment_started_at { Time.current }
      # FK to people(id). Build a real Person so the FK validates; callers
      # that want a specific manager can override `alignment_started_by_id`.
      alignment_started_by_id { create(:person, tenant: tenant).id }
    end

    trait :aligned do
      status { "aligned" }
      started_at { 2.days.ago }
      alignment_started_at { 1.day.ago }
      aligned_at { Time.current }
    end
  end
end
