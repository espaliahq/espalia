# frozen_string_literal: true

FactoryBot.define do
  factory :hris_sync_issue do
    tenant { ActsAsTenant.current_tenant }
    provider { "hibob" }
    kind { "in_structure" }
    unit_id { SecureRandom.uuid }
    first_seen_on { Date.new(2026, 11, 2) }
    last_seen_on { Date.new(2026, 11, 16) }
  end
end
