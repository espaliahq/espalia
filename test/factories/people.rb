FactoryBot.define do
  factory :person do
    association :tenant
    sequence(:email) { |n| "person#{n}@example.com" }
    name { "Alice Smith" }
    job_title { "Software Engineer" }
  end
end
