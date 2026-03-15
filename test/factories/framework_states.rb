# frozen_string_literal: true

FactoryBot.define do
  factory :framework_state, class: "FrameworkState::Framework" do
    tenant
    framework_id { SecureRandom.uuid_v7 }
    name { "Career Framework" }
  end

  factory :framework_role_family, class: "FrameworkState::RoleFamily" do
    tenant
    framework_id { SecureRandom.uuid_v7 }
    role_family_id { SecureRandom.uuid_v7 }
    name { "Engineering" }
  end

  factory :framework_role, class: "FrameworkState::Role" do
    tenant
    role_family_id { SecureRandom.uuid_v7 }
    role_id { SecureRandom.uuid_v7 }
    name { "Software Engineer" }
    code { "E" }
    track { "ic" }
  end

  factory :framework_level, class: "FrameworkState::Level" do
    tenant
    role_id { SecureRandom.uuid_v7 }
    level_id { SecureRandom.uuid_v7 }
    ordinal { 1 }
    title { "Software Engineer I" }
    code { "E1" }
    is_entry { false }
  end

  factory :framework_capability_category, class: "FrameworkState::CapabilityCategory" do
    tenant
    framework_id { SecureRandom.uuid_v7 }
    category_id { SecureRandom.uuid_v7 }
    name { "Thinking & Delivery" }
  end

  factory :framework_capability, class: "FrameworkState::Capability" do
    tenant
    category_id { SecureRandom.uuid_v7 }
    capability_id { SecureRandom.uuid_v7 }
    stable_id { SecureRandom.uuid_v7 }
    name { "Strategic Thinking" }
    status { "active" }
  end

  factory :framework_capability_role_binding, class: "FrameworkState::CapabilityRoleBinding" do
    tenant
    binding_id { SecureRandom.uuid_v7 }
    capability_id { SecureRandom.uuid_v7 }
    role_id { SecureRandom.uuid_v7 }
    weight { 1.0 }
    requirement_type { "must_have" }
  end

  factory :framework_behavioural_expectation, class: "FrameworkState::BehaviouralExpectation" do
    tenant
    expectation_id { SecureRandom.uuid_v7 }
    stable_id { SecureRandom.uuid_v7 }
    capability_id { SecureRandom.uuid_v7 }
    level_ordinal { 1 }
    description { "Asks questions to understand problems." }
  end

  factory :framework_role_illustration, class: "FrameworkState::RoleIllustration" do
    tenant
    illustration_id { SecureRandom.uuid_v7 }
    stable_id { SecureRandom.uuid_v7 }
    expectation_id { SecureRandom.uuid_v7 }
    role_id { SecureRandom.uuid_v7 }
    ordinal { 1 }
    description { "Seeks guidance from a tech lead on requirements." }
  end
end
