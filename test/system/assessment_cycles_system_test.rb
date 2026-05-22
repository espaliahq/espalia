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

      click_link_with_js_fallback("Define new cycle", expect_text: "Define a new cycle")

      # Set the Name field via JS — Selenium's send_keys can drop characters
      # on starved CI runners, leaving Name empty and the form rejected by
      # presence validation. Dispatch input/change events so any client-side
      # listeners see the new value.
      page.execute_script(<<~JS)
        const input = document.querySelector("input[name='assessment_cycle[name]']");
        if (input) {
          input.value = "Q2 2026 Review";
          input.dispatchEvent(new Event("input", { bubbles: true }));
          input.dispatchEvent(new Event("change", { bubbles: true }));
        }
      JS

      # Framework select defaults to the only option; cycle_type defaults to "regular"
      click_button_with_js_fallback("Define cycle", expect_text: "Cycle defined")

      assert_text "Q2 2026 Review"

      # Enroll the assigned person — set the select value via JS and submit
      # the enroll form via requestSubmit() because Capybara's pointer click
      # on the Enroll button has been silently dropped on starved CI runners.
      page.execute_script(<<~JS)
        const select = Array.from(document.querySelectorAll("select"))
          .find(s => Array.from(s.options).some(o => o.textContent.trim() === "Assigned Person"));
        if (select) {
          const opt = Array.from(select.options).find(o => o.textContent.trim() === "Assigned Person");
          if (opt) {
            select.value = opt.value;
            select.dispatchEvent(new Event("input", { bubbles: true }));
            select.dispatchEvent(new Event("change", { bubbles: true }));
          }
        }
        const btn = Array.from(document.querySelectorAll("button"))
          .find(b => b.textContent.trim() === "Enroll");
        btn?.closest("form")?.requestSubmit(btn);
      JS

      assert_text "Person enrolled"
      assert_text "Assigned Person"
      assert_text "enrolled@example.com".sub("enrolled", "assigned")

      # Unenroll (accept the confirm dialog)
      click_with_retry(expect_text: "Person unenrolled") do
        auto_confirm { click_button "Unenroll" }
      end
      assert_text "Withdrawn"

      # Close the cycle
      click_with_retry(expect_text: "Cycle closed") do
        auto_confirm { click_button "Close cycle" }
      end
      assert_text "Closed"
    end
  end

  context "inline cycle editing" do
    setup do
      @cycle_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        AssessmentCycles::CommandHandler.new.define_cycle(
          @cycle_id, @framework_id, "Q2 2026 Review", "regular", 1
        )
        @cycle = AssessmentCycle.find_by!(cycle_id: @cycle_id)
      end
    end

    should "rename, change type, and set the planned end date inline" do
      sign_in @admin_user
      visit assessment_cycle_path(@cycle)
      assert_text "Q2 2026 Review"

      # Rename via the name frame's inline editor.
      reveal_inline_form("#cycle-name-#{@cycle_id} [data-controller='inline-editor']")
      set_input_value("#cycle-name-#{@cycle_id} input[name='assessment_cycle[name]']", "Renamed H1 Review")
      submit_inline_form("#cycle-name-#{@cycle_id} [data-controller='inline-editor']")
      assert_text "Renamed H1 Review"

      # Change the cycle type via the type frame's <select>.
      reveal_inline_form("#cycle-type-#{@cycle_id} [data-controller='inline-editor']")
      set_input_value("#cycle-type-#{@cycle_id} select[name='assessment_cycle[cycle_type]']", "promotion_review")
      submit_inline_form("#cycle-type-#{@cycle_id} [data-controller='inline-editor']")
      assert_text "Promotion Review"

      # Set a planned end date.
      reveal_inline_form("#cycle-planned-end-#{@cycle_id} [data-controller='inline-editor']")
      set_input_value("#cycle-planned-end-#{@cycle_id} input[name='assessment_cycle[planned_end_at]']", "2026-06-30")
      submit_inline_form("#cycle-planned-end-#{@cycle_id} [data-controller='inline-editor']")
      assert_text "30 Jun 2026"

      # Clear the planned end date.
      reveal_inline_form("#cycle-planned-end-#{@cycle_id} [data-controller='inline-editor']")
      set_input_value("#cycle-planned-end-#{@cycle_id} input[name='assessment_cycle[planned_end_at]']", "")
      submit_inline_form("#cycle-planned-end-#{@cycle_id} [data-controller='inline-editor']")
      assert_text "not set"
    end

    should "hide edit affordances once the cycle is closed" do
      ActsAsTenant.with_tenant(@tenant) do
        AssessmentCycles::CommandHandler.new.close_cycle(@cycle_id)
      end

      sign_in @admin_user
      visit assessment_cycle_path(@cycle)
      assert_text "Closed"

      assert_no_selector "#cycle-name-#{@cycle_id} [data-controller='inline-editor']"
      assert_no_selector "#cycle-type-#{@cycle_id} [data-controller='inline-editor']"
      assert_no_selector "#cycle-planned-end-#{@cycle_id} [data-controller='inline-editor']"
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
      click_link_with_js_fallback("Open Cycle", expect_text: "New Hire")

      assert_text "New Hire"
      assert_text "newhire@example.com"
      assert_text "Enrolled"

      # Assertion at the model layer too, in case the UI changes
      ActsAsTenant.with_tenant(@tenant) do
        assert AssessmentCycleEnrollment.for_person(new_person_id).active.exists?,
          "expected auto-enrollment to create an enrollment row for the new hire"
      end
    end
  end

  private

  def sign_in(user)
    sign_in_as(user)
  end

  # Reveal the hidden inline-edit form for a given inline-editor scope by
  # toggling the display/form targets via JS — mirrors the framework
  # explorer pattern, which avoids dropped pointer clicks on the
  # opacity-0 pencil on slow CI runners.
  def reveal_inline_form(scope_selector)
    # The inline-editor controller extends Stimulus' Controller directly (no
    # `data-connected`), so wait_for_stimulus can't be used. We toggle the
    # display/form targets and submit via JS, neither of which needs the
    # controller connected — `find` waiting for the element is enough.
    container = find(scope_selector)
    page.execute_script(
      "arguments[0].querySelector('[data-inline-editor-target=\"display\"]').classList.add('hidden')", container
    )
    page.execute_script(
      "arguments[0].querySelector('[data-inline-editor-target=\"form\"]').classList.remove('hidden')", container
    )
  end

  # Atomically assign an input/select value via JS (Selenium send_keys can
  # drop characters on starved CI runners) and fire input/change events.
  def set_input_value(input_selector, value)
    page.execute_script(<<~JS, find(input_selector), value)
      const el = arguments[0];
      el.value = arguments[1];
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    JS
  end

  # Submit the inline form via requestSubmit() — synchronous, bypasses
  # pointer hit-testing so the Turbo frame request always fires.
  def submit_inline_form(scope_selector)
    page.execute_script("arguments[0].querySelector('form').requestSubmit();", find(scope_selector))
  end
end
