# frozen_string_literal: true

require "application_system_test_case"

# #471: the hero's "Gap to …" panel shows three rows. When more capabilities
# are short of the level, a "+N more" line says so and jumps to the next one.
class AssessmentHeroGapListSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  # Rated at E2 so four are short of it and one meets it. Two tie at 0%,
  # so the fourth-weakest gap is "Execution" whichever way the tie breaks.
  CAPABILITIES = {
    "Critical Thinking" => "none",
    "Problem Solving" => nil,
    "Communication" => "some",
    "Execution" => "occasional",
    "Ownership" => "consistent"
  }.freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Alice Engineer")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Gap List Framework")

      rf_id = SecureRandom.uuid_v7
      role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, role_id, rf_id, "Software Engineer", "E", "ic")
      level2_id = SecureRandom.uuid_v7
      handler.add_level(@framework_id, SecureRandom.uuid_v7, role_id, 1, "Junior", "E1", is_entry: true)
      handler.add_level(@framework_id, level2_id, role_id, 2, "Engineer", "E2")

      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Craft", ordinal: 1)

      @stable_ids = CAPABILITIES.keys.to_h do |name|
        cap_id = SecureRandom.uuid_v7
        stable_id = SecureRandom.uuid_v7
        handler.add_capability(@framework_id, cap_id, stable_id, cat_id, name)
        handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, role_id)
        [ 1, 2 ].each do |ordinal|
          handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                              cap_id, ordinal, "#{name} at E#{ordinal}")
        end
        [ name, stable_id ]
      end
      handler.publish_version(@framework_id, "test")

      pd_handler = PersonDevelopment::CommandHandler.new
      pd_handler.assign_to_framework(@person.id, @framework_id, role_id, level2_id)
      cycle_id = SecureRandom.uuid_v7
      cycle_handler = AssessmentCycles::CommandHandler.new
      cycle_handler.define_cycle(cycle_id, @framework_id, "Q4 Review", "regular", 1, defined_by: @person.id)
      cycle_handler.enroll(cycle_id, @person.id, enrolled_by: @person.id)

      CAPABILITIES.each do |name, frequency|
        next unless frequency

        pd_handler.rate_self(@person.id, @framework_id, @stable_ids.fetch(name),
                             level_ordinal: 2, frequency: frequency, cycle_id: cycle_id)
      end

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end

    sign_in_as(@user)
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
    should "jump from the +N more line to the next gap on #{label}" do
      page.driver.browser.manage.window.resize_to(*size)
      visit assessment_path(@assignment)
      assert_selector "#scoring-panel"

      within("#scoring-panel") do
        # Tailwind's `uppercase` re-cases the label.
        assert_text "GAP TO E2"
        assert_text "+1 more short of E2"
        assert_no_text "Execution"
        # Ownership meets E2, so it is never listed as a gap.
        assert_no_text "Ownership"
      end

      execution = @stable_ids.fetch("Execution")
      focused_card = "[data-matrix-target='card'][data-capability-stable-id='#{execution}'][data-focused='true']"
      click_selector_with_js_fallback("#scoring-panel a[href='#cell-#{execution}-2']",
                                      expect_selector: focused_card)

      assert_match(/level_ordinal=2/,
                   page.evaluate_script("document.querySelector('turbo-frame#assessment-matrix').getAttribute('src')"))
      # The jump is a smooth scroll, so wait for it to land.
      in_view = <<~JS
        (() => {
          const r = document.querySelector("#{focused_card}").getBoundingClientRect()
          return r.top >= 0 && r.top < window.innerHeight
        })()
      JS
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
      sleep 0.05 until page.evaluate_script(in_view) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      assert page.evaluate_script(in_view), "the next gap's card should be scrolled into view"
    end
  end
end
