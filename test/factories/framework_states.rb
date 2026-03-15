# frozen_string_literal: true

FactoryBot.define do
  factory :framework_state, class: "FrameworkState::Framework" do
    tenant
    framework_id { SecureRandom.uuid_v7 }
    name { "Career Framework" }
  end
end
