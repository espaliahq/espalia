# frozen_string_literal: true

FactoryBot.define do
  factory :tenant_user do
    association :tenant
    association :user
    role { :member }
  end
end
