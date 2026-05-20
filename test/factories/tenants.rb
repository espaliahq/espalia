# frozen_string_literal: true

FactoryBot.define do
  factory :tenant do
    sequence(:name) { |n| "Tenant #{n}" }
    sequence(:slug) { |n| "tenant-#{n}" }

    trait :with_hibob_config do
      hris_config do
        HrisConfig.new(
          provider: "hibob",
          sync_enabled: true,
          level_field_id: "column_test_id",
          role_mappings: [
            HrisRoleMapping.new(hris_titles: [ "Software Engineer" ], framework_role_code: "E"),
            HrisRoleMapping.new(hris_titles: [ "Engineering Manager" ], framework_role_code: "EM")
          ]
        )
      end
      hris_credentials do
        {
          "service_user_id" => "test-service-user",
          "api_token" => "test-api-token"
        }
      end
    end
  end
end
