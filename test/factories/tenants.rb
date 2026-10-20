# frozen_string_literal: true

FactoryBot.define do
  factory :tenant do
    sequence(:name) { |n| "Tenant #{n}" }
    sequence(:slug) { |n| "tenant-#{n}" }

    # A tenant with an AI model key stored and placement suggestions switched on.
    trait :with_ai_model do
      ai_config { AiModelConfig.new(provider: "anthropic", model: "claude-opus-5-5", suggestions_enabled: true) }
      ai_credentials { { "api_key" => "sk-test-key" } }
    end

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
