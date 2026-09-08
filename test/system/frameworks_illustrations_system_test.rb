# frozen_string_literal: true

require "application_system_test_case"

class FrameworksIllustrationsSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, role: :admin)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      @rid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      @eid = SecureRandom.uuid_v7
      @ill_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, @rid, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @rid, 1, "Engineer I", "E1", is_entry: true)
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, @rid)
      handler.set_behavioural_expectation(@framework_id, @eid, SecureRandom.uuid_v7, cap_id, 1, "Asks clarifying questions")
      handler.add_role_illustration(
        @framework_id, @ill_id, SecureRandom.uuid_v7, @eid, @rid, 1, "Seeks guidance from tech lead"
      )
      # Publish v1 so shape-changing events land in the read model
      handler.publish_version(@framework_id, "test")
    end

    sign_in_as(@user)
  end

  context "amending a pending illustration ghost" do
    # Regression: the ghost's amend form submits from inside the
    # pending-suggestion Turbo Frame; the endpoint's detail-page redirect
    # had no matching frame and rendered "Content missing" (and the
    # projection kept proposed_attributes stale, so even a reload showed
    # the pre-amend text).
    should "re-render the ghost with the amended text in place" do
      sid = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        person = Person.find_by(email: @user.email) ||
                 FactoryBot.create(:person, tenant: @tenant, email: @user.email)
        TenantUser.find_by(user_id: @user.id).update!(person: person)
        Frameworks::CommandHandler.new.suggest_create(
          @framework_id, sid, "role_illustration",
          { "role_id" => @rid, "description" => "Proposes alternatives when blocked" },
          parent_id: @eid, author_id: person.id.to_s, mode: :suggesting
        )
      end

      visit edit_framework_path(@framework_id)
      expand_matrix_row("tr[data-capability-id]")
      assert_text "Proposes alternatives when blocked"

      ghost = find("turbo-frame[id='pending-suggestion-#{sid}']")
      form = start_inline_edit(ghost)
      assert_equal "suggestion[suggested_value]",
                   form.find("[data-editor-input]", visible: :all)[:name]
      submit_inline_edit(form, with: "Proposes alternative solutions when blocked!")

      # The frame swaps in place with the amended value — before the fix
      # this rendered Turbo's "Content missing" instead.
      assert_text "Proposes alternative solutions when blocked!"
      assert_selector "turbo-frame[id='pending-suggestion-#{sid}']"
      assert_no_text "Content missing"
    end
  end

  context "inline illustration editing" do
    should "expand row and show illustration text" do
      visit edit_framework_path(@framework_id)

      # Expand the capability row using the matrix helper, which retries the
      # click if it was silently dropped on slow CI runners.
      expand_matrix_row("tr[data-capability-id]")

      # Illustration is now visible in the expanded row
      assert_text "Seeks guidance from tech lead"
    end

    should "allow saving updated illustration text inline" do
      visit edit_framework_path(@framework_id)

      # Expand the capability row using the matrix helper (retries on dropped clicks)
      expand_matrix_row("tr[data-capability-id]")
      assert_text "Seeks guidance from tech lead"

      # One shared editor for the whole explorer — the helper JS-dispatches the
      # pencil and returns the cloned form (testing.md, inline-editor rule).
      ill_li = find("li[data-editor-action*='/illustrations/']", match: :first)
      form = start_inline_edit(ill_li)
      submit_inline_edit(form, with: "Proactively seeks guidance and asks clarifying questions")

      assert_text "Proactively seeks guidance and asks clarifying questions"
      assert_no_text "Seeks guidance from tech lead"
    end

    should "cancel editing and restore original text" do
      visit edit_framework_path(@framework_id)

      # Expand the capability row using the matrix helper (retries on dropped clicks)
      expand_matrix_row("tr[data-capability-id]")
      assert_text "Seeks guidance from tech lead"

      ill_li = find("li[data-editor-action*='/illustrations/']", match: :first)
      form = start_inline_edit(ill_li)
      js_fill_in form.find("[data-editor-input]"), with: "This should not be saved"

      cancel_inline_edit(form)
      assert_no_selector "[data-editor-form]"

      # Edit form hidden, display mode restored — original text visible
      assert_text "Seeks guidance from tech lead"
    end
  end

  context "archiving an illustration" do
    should "remove the illustration directly for an approver in editing mode" do
      visit edit_framework_path(@framework_id)

      expand_matrix_row("tr[data-capability-id]")
      assert_text "Seeks guidance from tech lead"

      # The hover-revealed archive control posts a tiny confirm-guarded form.
      # Stub the confirm to true and submit it synchronously (the archive form
      # is the one in the display region — not the inline-editor edit form).
      ill_li = find("li[data-editor-action*='/illustrations/']", match: :first)
      auto_confirm do
        page.execute_script(
          "arguments[0].querySelector(\"form[action*='illustration_archives']\").requestSubmit();", ill_li
        )
      end

      # Redirected back to edit mode; the removal applied live (illustrations
      # carry no ratings, so it is shape-preserving). Sync on the flash — the
      # only text that exists solely on the far side of the redirect (the
      # capability name is on both pages, so waiting on it re-expands the row
      # about to be replaced, and the fetch then races the navigation).
      assert_text "Archived the illustration."
      # Re-expanding the row proves the illustration is gone, not merely collapsed.
      expand_matrix_row("tr[data-capability-id]")
      assert_no_text "Seeks guidance from tech lead"
    end
  end

  context "adding illustrations to a role with none yet" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        rfid2 = SecureRandom.uuid_v7
        @rid2 = SecureRandom.uuid_v7
        cap = FrameworkState::Capability.find_by(name: "Strategic Thinking")

        # Shape-changing commands (add_level, create_capability_role_binding)
        # require a draft. add_role_family and add_role are editorial/live.
        handler.add_role_family(@framework_id, rfid2, "Product")
        handler.add_role(@framework_id, @rid2, rfid2, "Product Manager", "PM", "ic")
        handler.start_draft(@framework_id, 2, "test")
        handler.add_level(@framework_id, SecureRandom.uuid_v7, @rid2, 1, "PM I", "PM1")
        handler.create_capability_role_binding(
          @framework_id, SecureRandom.uuid_v7, cap.capability_id, @rid2
        )
        handler.publish_version(@framework_id, "test")
      end
    end

    should "show Add illustration button when no illustrations exist for a role" do
      visit edit_framework_path(@framework_id)

      # Expand the capability row using the matrix helper (retries on dropped clicks)
      expand_matrix_row("tr[data-capability-id]")

      assert_selector "turbo-frame[id^='new-illustration-#{@eid}-']", visible: true
      assert_selector "button", text: "Add illustration"
    end

    should "allow adding a new illustration for a role that had none" do
      visit edit_framework_path(@framework_id)

      # Expand the capability row using the matrix helper (retries on dropped clicks)
      expand_matrix_row("tr[data-capability-id]")
      assert_selector "turbo-frame[id^='new-illustration-#{@eid}-']", visible: true

      add_div = find("turbo-frame[id='new-illustration-#{@eid}-#{@rid2}'] [data-editor-action]")
      form = start_inline_edit(add_div)
      submit_inline_edit(form, with: "Drives cross-functional alignment")

      # Wait for the Turbo Stream response to fully insert the new illustration.
      # On slow CI runners assert_text can read the page mid-render and only
      # see a partially-rendered element (visible-text-only); :all forces
      # Capybara to inspect the full DOM tree, including any visually-clipped
      # nodes during the Turbo append.
      assert_selector "li", text: "Drives cross-functional alignment", visible: :all
      assert_selector "button", text: "Add illustration"
    end

    should "cancel adding and restore the Add button without saving" do
      visit edit_framework_path(@framework_id)

      # Expand the capability row using the matrix helper (retries on dropped clicks)
      expand_matrix_row("tr[data-capability-id]")
      assert_selector "turbo-frame[id^='new-illustration-#{@eid}-']", visible: true

      add_div = find("turbo-frame[id='new-illustration-#{@eid}-#{@rid2}'] [data-editor-action]")
      form = start_inline_edit(add_div)
      js_fill_in form.find("[data-editor-input]"), with: "Should not be saved"

      cancel_inline_edit(form)

      assert_no_text "Should not be saved"
      assert_selector "button", text: "Add illustration"
    end
  end
end
