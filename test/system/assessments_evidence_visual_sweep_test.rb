# frozen_string_literal: true

require "application_system_test_case"

# Visual sweep — captures explicit screenshots of every interactive
# state in the evidence + activity feed UI so a reviewer can eyeball
# layout/colour/affordance correctness.
#
# Distinct from the other system tests (which use assertions to verify
# behaviour); this one uses `page.save_screenshot` to expose visual
# states that aren't otherwise auto-captured (modals opened via JS
# click, kebab menus, etc.).
#
# Run only manually with SCREENSHOTS=1; results land in tmp/screenshots/...
class AssessmentsEvidenceVisualSweepTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  SHOTS_DIR = Rails.root.join("tmp/screenshots/visual_sweep")

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    FileUtils.rm_rf(SHOTS_DIR)
    FileUtils.mkdir_p(SHOTS_DIR)

    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Alice Engineer")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      handler = Frameworks::CommandHandler.new
      pd_handler = PersonDevelopment::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Visual Sweep Framework")

      rf_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, @role_id, rf_id, "Software Engineer", "E", "ic")
      @level_id = SecureRandom.uuid_v7
      handler.add_level(@framework_id, @level_id, @role_id, 1, "Engineer 1", "E1", is_entry: true)
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @role_id, 2, "Engineer 2", "E2")

      @cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)
      @cat2_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, @cat2_id, "Delivery", ordinal: 2)

      @cap1_id = SecureRandom.uuid_v7
      @cap1_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap1_id, @cap1_stable, @cat_id, "Critical Thinking")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, @cap1_id, @role_id, weight: 1.0
      )
      handler.set_behavioural_expectation(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap1_id, 1,
        "Synthesises information"
      )

      @cap2_id = SecureRandom.uuid_v7
      @cap2_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap2_id, @cap2_stable, @cat2_id, "Shipping Quality")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, @cap2_id, @role_id, weight: 1.0
      )
      handler.set_behavioural_expectation(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap2_id, 1,
        "Lands changes safely"
      )

      handler.publish_version(@framework_id, "v1")

      level = FrameworkState::Level.find_by!(level_id: @level_id)
      pd_handler.assign_to_framework(@person.id, @framework_id, @role_id, level.level_id)

      cycle_handler = AssessmentCycles::CommandHandler.new
      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, @framework_id, "Q1", "regular", 1, defined_by: @person.id)
      cycle_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)

      pd_handler.rate_self(@person.id, @framework_id, @cap1_stable,
        level_ordinal: 1, frequency: "consistent", cycle_id: @cycle_id)

      @evidence_id = SecureRandom.uuid_v7
      pd_handler.record_evidence(@person.id, @framework_id, @evidence_id,
        capability_stable_id: @cap1_stable, level_ordinal: 1, source: "self",
        evidence_type: "project_outcome", title: "Onboarding redesign",
        content: "Owned the launch end-to-end; shipped on time with no rollbacks.",
        author_id: @person.id,
        external_reference: { system: "github", url: "https://github.com/x/y/pull/42" })

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end

    sign_in_as(@user)
  end

  context "visual sweep" do
    should "capture every interactive state" do
      visit assessment_path(@assignment, capability: @cap1_stable)
      shot("01_initial_load_with_evidence")

      # Activity pane open
      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      shot("02_activity_pane_open")

      # Filter chip set to Evidence
      page.execute_script(<<~JS)
        document.querySelector("[data-activity-feed-filter-param='evidence']").click();
      JS
      shot("03_activity_pane_filter_evidence")

      # Switch focus mode to Filter
      page.execute_script(<<~JS)
        document.querySelector("[data-activity-feed-filter-param='all']").click();
        document.querySelector("[data-activity-feed-mode-param='filter']").click();
      JS
      shot("04_activity_pane_focus_mode_filter")

      # Open the "+ Add evidence" modal
      page.execute_script(<<~JS)
        document.querySelector("[data-activity-feed-mode-param='highlight']").click();
        const btn = document.querySelector(
          "[data-evidence-form-capability-stable-id-param='#{@cap1_stable}']"
        );
        if (btn) btn.click();
      JS
      assert_selector "#evidence-form-modal", visible: true
      shot("05_add_evidence_modal_open")

      # Type "Other" so the custom-type-label field reveals
      page.execute_script(<<~JS)
        const f = document.querySelector("#evidence-form-modal form");
        f.querySelector("#evidence_type_field").value = "other";
        f.querySelector("#evidence_type_field").dispatchEvent(new Event("change"));
      JS
      shot("06_add_evidence_modal_other_reveals_custom_label")

      # Close the modal
      page.execute_script(<<~JS)
        document.querySelector(
          "[data-evidence-form-target='modal'] [data-action*='evidence-form#close']"
        ).click();
      JS
      shot("07_modal_closed")

      # Open the kebab on the existing evidence card
      page.execute_script(<<~JS)
        document.querySelector("#evidence-#{@evidence_id} [data-dropdown-target='trigger']").click();
      JS
      assert_selector "#evidence-#{@evidence_id} [role='menu']", visible: true
      shot("08_kebab_menu_open")

      # Open the relink modal
      page.execute_script(<<~JS)
        document.querySelector(
          "#evidence-#{@evidence_id} [data-action*='evidence-relink-form#open']"
        ).click();
      JS
      assert_selector "#evidence-relink-modal", visible: true
      shot("09_relink_modal_open_with_current_label")

      # Switch to a capability in the OTHER tab to show cross-tab feed entry
      page.execute_script(<<~JS)
        const f = document.querySelector("#evidence-relink-modal form");
        f.querySelector("#evidence_relink_capability_field").value = "#{@cap2_stable}";
        f.querySelector("#evidence_relink_level_field").value = "1";
        f.querySelector("#evidence_relink_rationale_field").value = "Better fit at L1 of Shipping Quality.";
      JS
      shot("10_relink_modal_filled")
    end
  end

  private

  def shot(name)
    page.save_screenshot(SHOTS_DIR.join("#{name}.png").to_s)
  end
end
