FactoryBot.define do
  factory :tenant do
    sequence(:name) { |n| "Tenant #{n}" }
    sequence(:slug) { |n| "tenant-#{n}" }

    trait :with_hibob_config do
      hris_config do
        HrisConfig.new(
          provider: "hibob",
          sync_enabled: true
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
