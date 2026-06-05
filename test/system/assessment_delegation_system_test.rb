# frozen_string_literal: true

require "application_system_test_case"

# End-to-end: a manager delegates manager-rating authority for a report to
# another person, and that delegate can review and rate the report.
class AssessmentDelegationSystemTest < ApplicationSystemTestCase
  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @manager_user = FactoryBot.create(:user, password: "password123")
    @delegate_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @manager = FactoryBot.create(:person, tenant: @tenant, email: @manager_user.email, name: "Manager Jane")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @delegate = FactoryBot.create(:person, tenant: @tenant, email: @delegate_user.email, name: "Delegate Dan")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @delegate_user, person: @delegate)

      @report = FactoryBot.create(:person, tenant: @tenant, name: "Report Alex", manager: @manager)

      handler = Frameworks::CommandHandler.new
      pd = PersonDevelopment::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Career Framework")
      rf_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, @role_id, rf_id, "Software Engineer", "E", "ic")
      @level2_id = SecureRandom.uuid_v7
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @role_id, 1, "Junior", "E1", is_entry: true)
      handler.add_level(@framework_id, @level2_id, @role_id, 2, "Senior", "E2")
      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      @cap_id = SecureRandom.uuid_v7
      @cap_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap_id, @cap_stable, cat_id, "Critical Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_id, @role_id, weight: 1.0)
      handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap_id, 2,
        "Synthesises information from multiple sources")
      handler.publish_version(@framework_id, "test")

      level = FrameworkState::Level.find_by!(level_id: @level2_id)
      pd.assign_to_framework(@report.id, @framework_id, @role_id, level.level_id)

      cycle = AssessmentCycles::CommandHandler.new
      @cycle_id = SecureRandom.uuid_v7
      cycle.define_cycle(@cycle_id, @framework_id, "Q1 2026", "regular", 1, defined_by: @manager.id)
      cycle.enroll(@cycle_id, @report.id, enrolled_by: @manager.id)

      @report_assignment = PersonFrameworkAssignment.for_person(@report.id).first
    end
  end

  test "manager grants a delegation through the Delegates modal" do
    sign_in_as(@manager_user)
    visit assessment_path(@report_assignment)
    assert_selector "h1", text: "Report Alex"

    open_delegates_modal
    within "#delegate-modal" do
      select "Delegate Dan", from: "Delegate to"
      click_button "Add delegate"
      assert_text "Delegate Dan" # now in the active-delegates list
    end

    ActsAsTenant.with_tenant(@tenant) do
      assert ManagerAssessmentDelegation.active_delegate?(
        person_id: @report.id, framework_id: @framework_id, delegate_person_id: @delegate.id
      )
    end
  end

  test "a delegate can review and rate the seconded report" do
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.delegate_manager_rating(
        @report.id, @framework_id, @delegate.id, granted_by_id: @manager.id
      )
    end

    sign_in_as(@delegate_user)
    visit assessments_path
    assert_text "Team Assessments"
    assert_text "Report Alex"

    visit assessment_path(@report_assignment, capability: @cap_stable)
    assert_selector "h1", text: "Report Alex"
    wait_for_stimulus "matrix"

    click_rating_frequency("#rating-#{@cap_stable}-2", "Consistently")
    assert_selector "#rating-#{@cap_stable}-2 button[aria-haspopup='menu']", text: "Consistently"

    # The delegate cannot start alignment — that stays manager-only.
    assert_no_button "Start alignment"
  end

  private

  def open_delegates_modal
    page.execute_script(<<~JS)
      const btn = Array.from(document.querySelectorAll("button"))
        .find(b => b.textContent.trim().startsWith("Delegates"));
      if (btn) btn.click();
    JS
    assert_selector "#delegate-modal", visible: true
  end
end
