# frozen_string_literal: true

require "application_system_test_case"

# WCAG 4.1.3 (audit issue #318): the acting user's rating changes are
# announced via a pre-existing polite live region. The visual acknowledgment
# (pill colour, hero count) previously had no non-visual counterpart — the
# region must exist BEFORE any text lands, be updated by the rating Turbo
# Stream responses, and never be touched by broadcasts.
class AssessmentsLiveStatusSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Alice")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      handler = Frameworks::CommandHandler.new
      pd_handler = PersonDevelopment::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test Framework")

      rf_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, @role_id, rf_id, "Software Engineer", "E", "ic")
      @level_id = SecureRandom.uuid_v7
      handler.add_level(@framework_id, @level_id, @role_id, 1, "Engineer 1", "E1", is_entry: true)

      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)

      cap_id = SecureRandom.uuid_v7
      @cap_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, cap_id, @cap_stable, cat_id, "Critical Thinking")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, cap_id, @role_id, weight: 1.0
      )
      handler.set_behavioural_expectation(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, cap_id, 1,
        "Synthesises information"
      )

      # Capability names are user-authored — the announcement must escape them
      # (turbo_stream.update marks string content html_safe).
      xss_cap_id = SecureRandom.uuid_v7
      @xss_cap_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, xss_cap_id, @xss_cap_stable, cat_id,
        "<img src=x onerror=window.__xss=1> & Co")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, xss_cap_id, @role_id, weight: 1.0
      )
      handler.set_behavioural_expectation(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, xss_cap_id, 1,
        "Does things"
      )

      handler.publish_version(@framework_id, "test")

      level = FrameworkState::Level.find_by!(level_id: @level_id)
      pd_handler.assign_to_framework(@person.id, @framework_id, @role_id, level.level_id)

      cycle_handler = AssessmentCycles::CommandHandler.new
      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, @framework_id, "Q1", "regular", 1, defined_by: @person.id)
      cycle_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first

      @manager_user = FactoryBot.create(:user, password: "password123")
      @manager = FactoryBot.create(:person, tenant: @tenant, email: @manager_user.email,
        name: "Morgan Manager")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @person.update!(manager: @manager)
    end

    sign_in_as(@user)
  end

  # JS expression locating the seeded cell's rating-pill dropdown wrapper —
  # the popover options and Clear item are clicked within it.
  # @return [String]
  def rating_wrapper_js
    "document.querySelector(\"#rating-#{@cap_stable}-1 [data-controller~='dropdown']\")"
  end

  # Opens the popover in the seeded cell and clicks the option whose label
  # contains +label+.
  # @return [void]
  def click_rating_option(label)
    page.execute_script("#{rating_wrapper_js}.querySelector(\"[data-dropdown-target='trigger']\").click();")
    page.execute_script(<<~JS)
      [...#{rating_wrapper_js}.querySelectorAll("button[type=submit]")]
        .find(b => b.textContent.includes(#{label.to_json})).click();
    JS
  end

  context "the live status region" do
    should "pre-exist empty, then announce rating and clearing" do
      visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all

      # 4.1.3: the region exists BEFORE any message is injected.
      assert_selector "#assessment-live-status[role='status']", visible: :all
      assert_equal "", page.evaluate_script(
        "document.getElementById('assessment-live-status').textContent"
      )

      wait_for_stimulus "submit-fallback", scope: "#rating-#{@cap_stable}-1"
      click_rating_option("Most of the time")
      assert_selector "#assessment-live-status",
        text: "Rated most of the time — Critical Thinking, E1", visible: :all

      # Clear via the popover's explicit item announces too.
      click_rating_option("Clear rating")
      assert_selector "#assessment-live-status",
        text: "Rating cleared — Critical Thinking, E1", visible: :all
    end

    should "render a hostile capability name as literal text, never as markup" do
      visit assessment_path(@assignment, capability: @xss_cap_stable, level_ordinal: 1)
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
      wait_for_stimulus "submit-fallback", scope: "#rating-#{@xss_cap_stable}-1"

      wrapper = "document.querySelector(\"#rating-#{@xss_cap_stable}-1 [data-controller~='dropdown']\")"
      page.execute_script("#{wrapper}.querySelector(\"[data-dropdown-target='trigger']\").click();")
      page.execute_script(<<~JS)
        [...#{wrapper}.querySelectorAll("button[type=submit]")]
          .find(b => b.textContent.includes("Consistently")).click();
      JS

      assert_selector "#assessment-live-status", text: "Rated consistently", visible: :all
      region_state = page.evaluate_script(<<~JS)
        (() => {
          const r = document.getElementById("assessment-live-status");
          return { text: r.textContent, injected: !!r.querySelector("img"), xss: !!window.__xss };
        })()
      JS
      assert_includes region_state["text"], "<img src=x onerror=window.__xss=1> & Co"
      assert_not region_state["injected"], "hostile name must not become an element"
      assert_not region_state["xss"], "hostile name must not execute"
    end
  end

  context "as the manager" do
    setup { sign_in_as(@manager_user) }

    should "announce manager rating and clearing" do
      visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
      wait_for_stimulus "submit-fallback", scope: "#rating-#{@cap_stable}-1"

      click_rating_option("Most of the time")
      assert_selector "#assessment-live-status",
        text: "Rated most of the time — Critical Thinking, E1", visible: :all

      click_rating_option("Clear rating")
      assert_selector "#assessment-live-status",
        text: "Rating cleared — Critical Thinking, E1", visible: :all
    end

    should "announce agreement and agreement clearing during alignment" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.start_alignment(
          @person.id, @framework_id, @cycle_id, started_by_id: @manager.id
        )
      end
      visit assessment_path(@assignment, capability: @cap_stable, level_ordinal: 1)
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
      wait_for_stimulus "submit-fallback", scope: "#rating-#{@cap_stable}-1"

      click_rating_option("Most of the time")
      assert_selector "#assessment-live-status",
        text: "Agreed most of the time — Critical Thinking, E1", visible: :all

      # Untoggling the agreed value clears the AGREEMENT, not a rating.
      click_rating_option("Most of the time")
      assert_selector "#assessment-live-status",
        text: "Agreement cleared — Critical Thinking, E1", visible: :all
    end
  end
end
