# frozen_string_literal: true

FactoryBot.define do
  factory :framework_publication do
    tenant
    framework_id { SecureRandom.uuid_v7 }
    draft_version { 2 }
    requested_by { association :tenant_user, tenant: tenant }
    status { :queued }
  end
end
