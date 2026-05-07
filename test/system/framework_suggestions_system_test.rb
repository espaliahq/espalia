# frozen_string_literal: true

require "application_system_test_case"

class FrameworkSuggestionsSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    @author_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = FactoryBot.create(:person, tenant: @tenant, email: @admin_user.email)
      @author_person = FactoryBot.create(:person, tenant: @tenant, email: @author_user.email)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @author_user, role: :member, person: @author_person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      @eid = SecureRandom.uuid_v7
      @ill_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "Engineer I", "E1", is_entry: true)
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, rid)
      handler.set_behavioural_expectation(@framework_id, @eid, SecureRandom.uuid_v7, cap_id,
                                          1, "Asks clarifying questions")
      handler.add_role_illustration(
        @framework_id, @ill_id, SecureRandom.uuid_v7, @eid, rid, 1, "Seeks guidance from tech lead"
      )
      handler.publish_version(@framework_id, "v1")

      # Add collaborator roles (required for suggestion access)
      handler.add_collaborator(@framework_id, @admin_person.id.to_s, "owner",
                               added_by: @admin_person.id.to_s)
      handler.add_collaborator(@framework_id, @author_person.id.to_s, "collaborator",
                               added_by: @admin_person.id.to_s)

      # Seed two pending suggestions, authored by @author_user, in mode :suggesting
      # so they don't auto-approve.
      @illustration_suggestion_id = SecureRandom.uuid_v7
      handler.suggest_edit(
        @framework_id, @illustration_suggestion_id,
        "role_illustration", @ill_id, "description",
        "Proactively asks clarifying questions of the tech lead",
        @author_person.id.to_s, mode: :suggesting
      )

      @expectation_suggestion_id = SecureRandom.uuid_v7
      handler.suggest_edit(
        @framework_id, @expectation_suggestion_id,
        "behavioural_expectation", @eid, "description",
        "Asks open-ended questions to surface assumptions",
        @author_person.id.to_s, mode: :suggesting
      )
    end
  end

  context "as an admin reviewer" do
    setup { sign_in_as(@admin_user) }

    should "list pending suggestions on the framework suggestions page" do
      visit framework_suggestions_path(@framework_id)

      assert_text "Suggested edits"
      assert_text "Proactively asks clarifying questions of the tech lead"
      assert_text "Asks open-ended questions to surface assumptions"
      assert_text(/tier 1/i)
      assert_text(/tier 3/i)
    end

    should "approve a tier 3 expectation suggestion and apply the change to the read model" do
      visit framework_suggestion_path(@framework_id, @expectation_suggestion_id)

      assert_text "Suggested edit"
      assert_text "Asks open-ended questions to surface assumptions"

      click_button "Approve"

      assert_current_path framework_suggestions_path(@framework_id)
      assert_text "Suggestion approved"

      ActsAsTenant.with_tenant(@tenant) do
        expectation = FrameworkState::BehaviouralExpectation.find_by(expectation_id: @eid)
        assert_equal "Asks open-ended questions to surface assumptions", expectation.description
      end
    end

    should "reject a pending suggestion" do
      visit framework_suggestion_path(@framework_id, @illustration_suggestion_id)

      click_with_retry(expect_text: "Suggestion rejected") do
        auto_confirm { click_button "Reject" }
      end

      assert_current_path framework_suggestions_path(@framework_id)

      ActsAsTenant.with_tenant(@tenant) do
        suggestion = FrameworkState::SuggestedEdit.find_by(suggestion_id: @illustration_suggestion_id)
        assert_equal "rejected", suggestion.status
      end
    end

    should "show the suggestions toggle in the framework explorer header (edit mode only)" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      visit edit_framework_path(@framework_id)

      wait_for_stimulus "framework-explorer"
      assert_selector "button", text: /Suggestions/
    end
  end

  context "as the author" do
    setup { sign_in_as(@author_user) }

    should "withdraw their own pending suggestion" do
      visit framework_suggestion_path(@framework_id, @illustration_suggestion_id)

      # Wait for the page to finish rendering before clicking — on slow
      # CI runners the click can fire before Turbo's confirm handler is
      # bound, silently dropping the submit and timing out the modal wait.
      assert_selector "form[data-turbo-confirm] button", text: "Withdraw"

      # Submit the form via requestSubmit() so a starved CI runner can't
      # drop the click — same primitive used for the manager untoggle.
      # Stub window.confirm first so Turbo's data-turbo-confirm handler
      # resolves synchronously without showing a dialog.
      auto_confirm do
        page.execute_script(<<~JS)
          const btn = Array.from(document.querySelectorAll("form[data-turbo-confirm] button"))
            .find(b => b.textContent.trim() === "Withdraw");
          btn?.closest("form")?.requestSubmit(btn);
        JS
      end

      assert_text "Suggestion withdrawn"
      assert_current_path framework_suggestions_path(@framework_id)

      ActsAsTenant.with_tenant(@tenant) do
        suggestion = FrameworkState::SuggestedEdit.find_by(suggestion_id: @illustration_suggestion_id)
        assert_equal "withdrawn", suggestion.status
      end
    end
  end
end
