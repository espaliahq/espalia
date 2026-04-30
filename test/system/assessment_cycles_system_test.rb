# frozen_string_literal: true

require "application_system_test_case"

class AssessmentCyclesSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = FactoryBot.create(
        :person, tenant: @tenant, email: @admin_user.email, name: "Admin User"
      )
      FactoryBot.create(
        :tenant_user,
        tenant: @tenant, user: @admin_user, person: @admin_person, role: :admin
      )

      @framework_id = SecureRandom.uuid_v7
      @framework = FactoryBot.create(
        :framework_state,
        framework_id: @framework_id,
        name: "Engineering Growth",
        current_published_version: 1
      )
      rf = FactoryBot.create(:framework_role_family, framework_id: @framework_id, name: "Engineering")
      @role = FactoryBot.create(
        :framework_role,
        role_family_id: rf.role_family_id, name: "Software Engineer", code: "E", track: "ic"
      )
      @level = FactoryBot.create(
        :framework_level,
        role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2"
      )

      @assigned_person = FactoryBot.create(
        :person, tenant: @tenant, name: "Assigned Person", email: "assigned@example.com"
      )
      PersonDevelopment::CommandHandler.new.assign_to_framework(
        @assigned_person.id, @framework_id, @role.role_id, @level.level_id
      )
    end

    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
  end

  context "end-to-end cycle lifecycle" do
    should "define, enroll, unenroll, and close a cycle" do
      sign_in @admin_user
      visit assessment_cycles_path

      assert_text "Assessment Cycles"
      assert_text "Open (0)"

      click_with_retry(expect_text: "Define a new cycle") { click_link "Define new cycle" }

      fill_in "Name", with: "Q2 2026 Review"
      # Framework select defaults to the only option; cycle_type defaults to "regular"
      click_with_retry(expect_text: "Cycle defined") { click_button "Define cycle" }

      assert_text "Q2 2026 Review"

      # Enroll the assigned person
      select "Assigned Person", from: "Person"
      click_button "Enroll"

      assert_text "Person enrolled"
      assert_text "Assigned Person"
      assert_text "enrolled@example.com".sub("enrolled", "assigned")

      # Unenroll (accept the confirm dialog)
      accept_confirm_with_retry do
        click_button "Unenroll"
      end
      assert_text "Person unenrolled"
      assert_text "Withdrawn"

      # Close the cycle
      accept_confirm_with_retry do
        click_button "Close cycle"
      end
      assert_text "Cycle closed"
      assert_text "Closed"
    end
  end

  context "auto-enrollment on new assignment" do
    should "auto-enroll a newly-assigned person into the open cycle" do
      # Define a cycle first via the rails layer so the UI test stays focused
      ActsAsTenant.with_tenant(@tenant) do
        AssessmentCycles::CommandHandler.new.define_cycle(
          SecureRandom.uuid_v7, @framework_id, "Open Cycle", "regular", 1
        )
      end

      # Simulate an HRIS-driven new hire: assign a fresh Person to the
      # framework. The AutoEnrollNewAssignments sync handler should fire
      # synchronously and create the participant row.
      new_person_id = nil
      ActsAsTenant.with_tenant(@tenant) do
        new_person = FactoryBot.create(
          :person, tenant: @tenant, name: "New Hire", email: "newhire@example.com"
        )
        new_person_id = new_person.id

        Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
          PersonDevelopment::CommandHandler.new.assign_to_framework(
            new_person.id, @framework_id, @role.role_id, @level.level_id
          )
        end
      end

      # Visit the cycle in the UI and confirm the auto-enrolled participant appears
      sign_in @admin_user
      visit assessment_cycles_path
      # Wait for the index to fully render before clicking through. Without
      # this synchronisation, the click can land on a stale link and be
      # silently dropped on slow CI runners.
      assert_text "Assessment Cycles"
      click_with_retry(expect_text: "New Hire") { click_link "Open Cycle" }

      assert_text "New Hire"
      assert_text "newhire@example.com"
      assert_text "Enrolled"

      # Assertion at the model layer too, in case the UI changes
      ActsAsTenant.with_tenant(@tenant) do
        assert AssessmentCycleParticipant.for_person(new_person_id).active.exists?,
          "expected auto-enrollment to create a participant row for the new hire"
      end
    end
  end

  private

  def sign_in(user)
    sign_in_as(user)
  end
end
