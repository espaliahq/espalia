# frozen_string_literal: true

require "application_system_test_case"

# A manager's team as one set of capability blades: the card at the head of
# Team Assessments, and the team map it opens, at desktop and phone widths.
class TeamBladesSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE = [ 375, 812 ].freeze

  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @manager = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Morgan Vale")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: @manager)

      @framework_id = SecureRandom.uuid_v7
      FactoryBot.create(:framework_state, framework_id: @framework_id, name: "Engineering Growth")
      family = FactoryBot.create(:framework_role_family, framework_id: @framework_id, name: "Engineering")
      @role = FactoryBot.create(:framework_role, role_family_id: family.role_family_id, name: "Software Engineer",
                                                 code: "E", track: "ic")
      @levels = (1..3).to_h do |ordinal|
        [ ordinal, FactoryBot.create(:framework_level, role_id: @role.role_id, ordinal:, title: "E#{ordinal}", code: "E#{ordinal}") ]
      end
      category = FactoryBot.create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      @capabilities = [ "Player coach", "Delivery" ].map do |name|
        capability = FactoryBot.create(:framework_capability, category_id: category.category_id, name:)
        FactoryBot.create(:framework_capability_role_binding, capability_id: capability.capability_id, role_id: @role.role_id)
        (1..3).each do |ordinal|
          FactoryBot.create(:framework_behavioural_expectation, capability_id: capability.capability_id, level_ordinal: ordinal)
        end
        capability
      end
      @cycle_id = SecureRandom.uuid_v7
      AssessmentCycles::CommandHandler.new.define_cycle(@cycle_id, @framework_id, "H2 2026 review", "regular", 1)
    end
  end

  # Assigning a report enrols them in the open cycle; the manager then rates each capability.
  def add_report(name, level, *frequencies)
    ActsAsTenant.with_tenant(@tenant) do
      report = FactoryBot.create(:person, tenant: @tenant, name:, manager: @manager)
      handler = PersonDevelopment::CommandHandler.new
      handler.assign_to_framework(report.id, @framework_id, @role.role_id, @levels.fetch(level).level_id)
      AssessmentCycles::CommandHandler.new.enroll(@cycle_id, report.id) unless
        AssessmentCycleEnrollment.exists?(cycle_id: @cycle_id, person_id: report.id)
      @capabilities.zip(frequencies).each do |capability, frequency|
        next unless frequency

        handler.rate_as_manager(report.id, @framework_id, capability.stable_id, level_ordinal: level,
                                                                                 frequency:, cycle_id: @cycle_id, rated_by_id: @manager.id)
      end
    end
  end

  def visit_team(size)
    page.driver.browser.manage.window.resize_to(*size)
    sign_in_as(@user)
    visit assessments_path
    assert_selector "#team-card", text: "Your team’s shape"
  end

  context "a team with scores" do
    setup do
      add_report("Ari Novak", 2, "none", "consistent")
      add_report("Dani Reyes", 2, "some", "consistent")
      add_report("Bea Lindqvist", 3, "consistent", "consistent")
    end

    should "show the team's blades and common gaps, and open the team map" do
      visit_team(DESKTOP_SIZE)

      assert_selector "#team-card [data-team-blades][aria-label='1 of 2 capabilities met as a team']", visible: true
      assert_selector "#team-card [data-team-gap]", text: "Player coach · 2 of 3 short"
      click_button_with_js_fallback("Open team map", expect_text: "Your 3 direct reports, manager ratings")
      assert_selector "#team-map [data-team-lane]", count: 2, visible: true

      click_link_with_js_fallback("E3 1", expect_text: "Your 1 direct report at E3")
      within("#team-map") { assert_no_text "Ari Novak" }
    end

    should "stack the map's blades above its lanes on a phone" do
      visit_team(MOBILE_SIZE)
      assert_no_sideways_overflow

      click_button_with_js_fallback("Open team map", expect_text: "Your 3 direct reports, manager ratings")
      assert_selector "#team-map [data-team-lane]", count: 2, visible: true
      blades_bottom = evaluate_script("document.querySelector('#team-map [data-team-blades]').getBoundingClientRect().bottom")
      lane_top = evaluate_script("document.querySelector('#team-map [data-team-lane]').getBoundingClientRect().top")
      assert_operator blades_bottom, :<=, lane_top, "expected the blades above the lanes"
    end
  end

  should "show a blank slate until two reports have a score, with no team map" do
    add_report("Ari Novak", 2, "consistent", "consistent")
    add_report("Dani Reyes", 2)
    visit_team(MOBILE_SIZE)

    assert_selector "#team-card [data-team-blank]", visible: true
    assert_text "1 of 2 has one so far"
    assert_no_button "Open team map"
    assert_no_sideways_overflow
  end
end
