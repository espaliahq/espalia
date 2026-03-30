FactoryBot.define do
  factory :framework_collaborator, class: "FrameworkState::Collaborator" do
    association :tenant
    framework_id { SecureRandom.uuid_v7 }
    person_id { SecureRandom.uuid_v7 }
    role { "viewer" }
    scope_type { nil }
    scope_id { nil }
  end
end
