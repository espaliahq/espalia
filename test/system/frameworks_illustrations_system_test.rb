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

      # The inline-editor controller is on each illustration li.
      # Trigger startEdit via JS (simulates hover + click on the hidden edit button)
      ill_li = find("li[data-controller='inline-editor']", match: :first)
      page.execute_script("arguments[0].querySelector('[data-inline-editor-target=\"display\"]').classList.add('hidden')", ill_li)
      page.execute_script("arguments[0].querySelector('[data-inline-editor-target=\"form\"]').classList.remove('hidden')", ill_li)

      # Fill in the textarea and submit
      textarea = ill_li.find("textarea[name='illustration[description]']")
      textarea.fill_in with: "Proactively seeks guidance and asks clarifying questions"

      # Submit via the form's requestSubmit() rather than a Capybara button
      # click — on slow CI runners the button click is silently dropped, but
      # invoking the form's submit method synchronously bypasses Selenium's
      # pointer hit-testing entirely and the data-turbo-stream response is
      # guaranteed to fire.
      page.execute_script("arguments[0].querySelector('form').requestSubmit();", ill_li)

      assert_text "Proactively seeks guidance and asks clarifying questions"
      assert_no_text "Seeks guidance from tech lead"
    end

    should "cancel editing and restore original text" do
      visit edit_framework_path(@framework_id)

      # Expand the capability row using the matrix helper (retries on dropped clicks)
      expand_matrix_row("tr[data-capability-id]")
      assert_text "Seeks guidance from tech lead"

      ill_li = find("li[data-controller='inline-editor']", match: :first)
      page.execute_script("arguments[0].querySelector('[data-inline-editor-target=\"display\"]').classList.add('hidden')", ill_li)
      page.execute_script("arguments[0].querySelector('[data-inline-editor-target=\"form\"]').classList.remove('hidden')", ill_li)

      textarea = ill_li.find("textarea[name='illustration[description]']")
      textarea.fill_in with: "This should not be saved"

      ill_li.find("button[data-action='inline-editor#cancel']", match: :first).click

      # Edit form hidden, display mode restored — original text visible
      assert_text "Seeks guidance from tech lead"
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

      add_div = find("turbo-frame[id='new-illustration-#{@eid}-#{@rid2}']")
        .find("div[data-controller='inline-editor']")
      page.execute_script("arguments[0].querySelector('[data-inline-editor-target=\"display\"]').classList.add('hidden')", add_div)
      page.execute_script("arguments[0].querySelector('[data-inline-editor-target=\"form\"]').classList.remove('hidden')", add_div)

      textarea = add_div.find("textarea[name='illustration[description]']")
      textarea.fill_in with: "Drives cross-functional alignment"

      # Submit via requestSubmit (see comment above for rationale)
      page.execute_script("arguments[0].querySelector('form').requestSubmit();", add_div)
      assert_text "Drives cross-functional alignment"
      assert_selector "button", text: "Add illustration"
    end

    should "cancel adding and restore the Add button without saving" do
      visit edit_framework_path(@framework_id)

      # Expand the capability row using the matrix helper (retries on dropped clicks)
      expand_matrix_row("tr[data-capability-id]")
      assert_selector "turbo-frame[id^='new-illustration-#{@eid}-']", visible: true

      add_div = find("turbo-frame[id='new-illustration-#{@eid}-#{@rid2}']")
        .find("div[data-controller='inline-editor']")
      page.execute_script("arguments[0].querySelector('[data-inline-editor-target=\"display\"]').classList.add('hidden')", add_div)
      page.execute_script("arguments[0].querySelector('[data-inline-editor-target=\"form\"]').classList.remove('hidden')", add_div)

      textarea = add_div.find("textarea[name='illustration[description]']")
      textarea.fill_in with: "Should not be saved"

      add_div.find("button[data-action='inline-editor#cancel']").click

      assert_no_text "Should not be saved"
      assert_selector "button", text: "Add illustration"
    end
  end
end
