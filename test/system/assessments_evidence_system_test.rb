# frozen_string_literal: true

require "application_system_test_case"

class AssessmentsEvidenceSystemTest < ApplicationSystemTestCase
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

      @cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)

      @cap_id = SecureRandom.uuid_v7
      @cap_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap_id, @cap_stable, @cat_id, "Critical Thinking")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, @cap_id, @role_id, weight: 1.0
      )
      handler.set_behavioural_expectation(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap_id, 1,
        "Synthesises information"
      )

      handler.publish_version(@framework_id, "test")

      level = FrameworkState::Level.find_by!(level_id: @level_id)
      pd_handler.assign_to_framework(@person.id, @framework_id, @role_id, level.level_id)

      cycle_handler = AssessmentCycles::CommandHandler.new
      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, @framework_id, "Q1", "regular", 1, defined_by: @person.id)
      cycle_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end

    sign_in_as(@user)
  end

  context "evidence modal" do
    # The full create flow is covered end-to-end by the integration test in
    # test/controllers/assessments/evidence_controller_test.rb. The system
    # test's unique value is asserting the Stimulus wiring: the
    # hover-revealed "+ Add evidence" trigger inside the matrix turbo-frame
    # actually opens the modal hosted on the page wrapper, and the
    # capability + level coords are primed correctly.
    should "open with the cell's capability and level pre-populated" do
      visit assessment_path(@assignment)
      wait_for_stimulus "evidence-form"
      expand_matrix_row("#capability-name-#{@cap_stable}")
      assert_selector "[data-evidence-form-capability-stable-id-param='#{@cap_stable}']",
        visible: :all

      page.execute_script(<<~JS)
        document.querySelector(
          "[data-evidence-form-capability-stable-id-param='#{@cap_stable}']"
        ).click();
      JS
      assert_selector "#evidence-form-modal", visible: true

      cap_field, level_field = page.evaluate_script(<<~JS)
        (() => {
          const f = document.querySelector("#evidence-form-modal form");
          return [
            f.querySelector("[name='evidence[capability_stable_id]']").value,
            f.querySelector("[name='evidence[level_ordinal]']").value
          ];
        })()
      JS
      assert_equal @cap_stable, cap_field
      assert_equal "1", level_field
    end
  end
end
