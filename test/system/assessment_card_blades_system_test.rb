# frozen_string_literal: true

require "application_system_test_case"

# The capability blades on an assessment card: the shape always, its caption
# only where the card has room, never at the cost of the card's button.
class AssessmentCardBladesSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE = [ 375, 812 ].freeze
  AVATAR = "[data-capability-blades]"

  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Alice Engineer")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: person)

      framework_id = SecureRandom.uuid_v7
      FactoryBot.create(:framework_state, framework_id: framework_id, name: "Engineering Growth")
      family = FactoryBot.create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      role = FactoryBot.create(:framework_role, role_family_id: family.role_family_id, name: "Software Engineer",
                                                code: "E", track: "ic")
      FactoryBot.create(:framework_level, role_id: role.role_id, ordinal: 1, title: "Junior", code: "E1")
      level = FactoryBot.create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      category = FactoryBot.create(:framework_capability_category, framework_id: framework_id, name: "Thinking",
                                                                   ordinal: 1)
      capabilities = %w[Delivery Quality].map do |name|
        capability = FactoryBot.create(:framework_capability, category_id: category.category_id, name: name)
        FactoryBot.create(:framework_capability_role_binding, capability_id: capability.capability_id,
                                                              role_id: role.role_id)
        [ 1, 2 ].each do |ordinal|
          FactoryBot.create(:framework_behavioural_expectation, capability_id: capability.capability_id,
                                                                level_ordinal: ordinal)
        end
        capability
      end

      handler = PersonDevelopment::CommandHandler.new
      handler.assign_to_framework(person.id, framework_id, role.role_id, level.level_id)
      cycle_id = SecureRandom.uuid_v7
      AssessmentCycles::CommandHandler.new.define_cycle(cycle_id, framework_id, "H2 2026 review", "regular", 1)
      AssessmentCycles::CommandHandler.new.enroll(cycle_id, person.id)
      capabilities.each do |capability|
        handler.rate_self(person.id, framework_id, capability.stable_id, level_ordinal: 2, frequency: "consistent",
                                                                         cycle_id: cycle_id)
      end
    end
  end

  should "name what the blades show beside them on a wide card" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@user)
    visit assessments_path

    assert_selector "#{AVATAR} svg[role='img'][aria-label='2 of 2 capabilities met at E2']", visible: true
    assert_selector "#{AVATAR} [data-blades-caption]", text: /2 of 2\s+met at E2/, visible: true
  end

  should "keep only the shape on a phone, with the card's button on one line" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    sign_in_as(@user)
    visit assessments_path

    assert_selector "#{AVATAR} svg[aria-label='2 of 2 capabilities met at E2']", visible: true
    assert_no_selector "#{AVATAR} [data-blades-caption]", visible: true
    button = find_link(text: /self-assessment/)
    assert_operator button.evaluate_script("this.getBoundingClientRect().height"), :<=, 48,
                    "expected the button's label on one line"
    assert_no_sideways_overflow
  end

  should "show the caption only where it fits beside the button, at any card width" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@user)
    visit assessments_path
    assert_selector AVATAR

    (760..1400).step(40).each do |width|
      page.driver.browser.manage.window.resize_to(width, 900)
      spill = evaluate_script(<<~JS)
        (() => { const row = document.querySelector("#{AVATAR}").parentElement; return row.scrollWidth - row.clientWidth })()
      JS
      assert_equal 0, spill, "expected the card's footer to fit at a #{width}px window"
    end
  end
end
