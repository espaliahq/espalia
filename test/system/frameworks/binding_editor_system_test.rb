# frozen_string_literal: true

require "application_system_test_case"

# The "Edit roles" binding editor — row-actions kebab → shared modal whose
# Turbo Frame body lists a capability's role bindings and lets an edit-rights
# holder add / remove them in place. Re-scoping (add/remove) is the editor's
# headline; weight editing is covered at the controller/operation layer.
class Frameworks::BindingEditorSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      @role_e = SecureRandom.uuid_v7
      @role_em = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, @role_e, rfid, "Software Engineer", "E", "ic")
      handler.add_role(@framework_id, @role_em, rfid, "Engineering Manager", "EM", "management")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @role_e, 1, "Engineer I", "E1", is_entry: true)
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, @role_e)
      handler.publish_version(@framework_id, "test")
    end
  end

  # JS-click the hover-revealed kebab + the "Edit roles…" item (Selenium pointer
  # clicks on the opacity-0 control flake on starved CI), then wait for the
  # modal's Turbo Frame to load.
  def open_binding_editor(size: DESKTOP_SIZE)
    visit_edit_mode(size: size)
    trigger_binding_editor

    assert_selector "#binding-editor-modal", visible: true
    assert_selector "turbo-frame#binding-editor", visible: true
    assert_text "Engineering Manager" # the unbound role offered in the add select
  end

  # Sign in and land on the edit-mode explorer with the matrix settled.
  private def visit_edit_mode(size: DESKTOP_SIZE)
    page.driver.browser.manage.window.resize_to(*size)
    sign_in_as(@admin_user)
    visit edit_framework_path(@framework_id)
    wait_for_stimulus "matrix"
  end

  # `patch_fetch` is shared — test/support/system/fetch_stub_helpers.rb.
  # Submit the data-turbo-confirm Remove form via requestSubmit() (the
  # documented JS-submit remedy for the flaky confirm-form click on starved
  # CI — testing.md). auto_confirm stubs window.confirm so Turbo proceeds.
  def remove_only_binding
    auto_confirm do
      page.execute_script(
        'document.querySelector("#binding-editor form[data-turbo-confirm]").requestSubmit();'
      )
    end
  end

  # The pill and the Publish button sit outside the editor's frame; only the
  # draft-opened broadcast reaches them (#496). The activity feed also says
  # "draft", so assert the header slots themselves.
  def assert_header_shows_draft
    assert_selector "#framework-draft-badge", text: "v2 draft"
    assert_selector "#framework-publish-action a", text: "Publish v2"
  end

  def subscribed_streams
    all("turbo-cable-stream-source", visible: :all).map do |source|
      Turbo::StreamsChannel.verified_stream_name(source["signed-stream-name"])
    end
  end

  def trigger_binding_editor
    assert_selector "button[aria-label='Capability actions']", visible: :all
    page.execute_script('document.querySelector("button[aria-label=\'Capability actions\']").click();')
    assert_text "Edit roles…"
    page.execute_script(<<~JS)
      [...document.querySelectorAll("[role='menuitem']")]
        .find((b) => b.textContent.trim().startsWith("Edit roles")).click();
    JS
  end

  context "as a tenant admin in edit mode" do
    should "add a role binding, re-scoping the capability" do
      open_binding_editor

      within "#binding-editor" do
        assert_text "Software Engineer" # already bound
        select "EM · Engineering Manager", from: "Add a role"
      end
      click_button_with_js_fallback("Add role", expect_text: "Bound to every role.")

      # Both roles bound now → the add select is gone, and the new (draft) binding
      # carries the wiggle (the universal "differs from published" signal), not a
      # "New in draft" pill.
      within "#binding-editor" do
        assert_text "Bound to every role."
        assert_no_text "New in draft"
        assert_selector "span.decoration-amber-400", text: "Engineering Manager"
      end
      assert_header_shows_draft
    end

    # Audit issue #365: an un-handled frame failure rendered Turbo's own
    # "Content missing" into the editor (or left "Loading…" standing) inside
    # the multi-megabyte edit-mode explorer, with no retry.
    should "surface a retryable error when the editor frame fails to load" do
      visit_edit_mode
      patch_fetch("capability_bindings", respond: :reject, once: true)
      trigger_binding_editor

      assert_selector "#binding-editor-modal", visible: true
      assert_selector "#binding-editor-error", text: "Couldn't load the roles editor", visible: true
      assert_no_selector "turbo-frame#binding-editor", visible: true
      assert_no_text "Content missing"

      page.execute_script('document.querySelector("#binding-editor-error button").click();')

      assert_selector "#binding-editor select#binding-add-role", visible: true
      assert_no_selector "#binding-editor-error", visible: true
    end

    # The other half of that rule: `frame-error` speaks for the frame's own
    # GET, never for a form submitted INSIDE it. Turbo dispatches
    # `turbo:frame-missing` on the frame either way (verified in
    # turbo-rails 2.0.23: `formSubmissionFailedWithResponse` →
    # `loadResponse` → `#willHandleFrameMissingFromResponse`, whose dispatch
    # target is `this.element`), so claiming it unconditionally hid the whole
    # editor — every row, and any weight the user had typed into another —
    # behind "Couldn't load…", whose Retry then re-GETs over that work.
    should "leave a failed in-frame form submission to Turbo" do
      open_binding_editor

      # A 500 HTML body to the weight PATCH: no <turbo-frame> in it, so this is
      # exactly the frame-missing shape — arriving from a submission, not a load.
      patch_fetch("capability_bindings")
      page.execute_script(
        'document.querySelector("#binding-editor form input[name=\'binding[weight]\']")' \
        ".closest('form').requestSubmit();"
      )

      # The POST genuinely left — otherwise the assertions below would pass on
      # a dropped submit having proved nothing.
      assert_fetch_matched 1

      # Our error never claims it, and the editor stays standing. Turbo's own
      # default owns the response from here (its copy is not our contract).
      assert_no_selector "#binding-editor-error", visible: true
      assert_selector "turbo-frame#binding-editor", visible: true
    end

    [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
      should "remove the only role binding and show the draft it opened in the header (#{label})" do
        open_binding_editor(size: size)
        assert_no_selector "#framework-publish-action a"

        remove_only_binding

        within "#binding-editor" do
          assert_text "Not bound to any role yet."
        end
        assert_header_shows_draft
      end
    end
  end

  # #496: the bar to edit a binding is lower than the bar to publish, so the
  # draft a role lead opens must reach their header without its Publish button.
  context "as a role lead without publish rights" do
    setup do
      @lead_user = FactoryBot.create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        lead = FactoryBot.create(:person, tenant: @tenant, email: @lead_user.email)
        FactoryBot.create(:tenant_user, tenant: @tenant, user: @lead_user, person: lead, role: :member)
        Frameworks::CommandHandler.new.add_collaborator(
          @framework_id, lead.id.to_s, "role_lead", scope_type: "role", scope_id: @role_e, added_by: lead.id.to_s
        )
      end
    end

    should "show the draft pill but never the Publish button" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@lead_user)
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      trigger_binding_editor
      assert_selector "turbo-frame#binding-editor", visible: true
      assert_text "Software Engineer"

      remove_only_binding

      assert_selector "#framework-draft-badge", text: "v2 draft"
      assert_no_selector "#framework-publish-action a"
      # The absence above can't wait for a button that arrives late, so prove
      # the page never joined the stream that carries it.
      assert_not_includes subscribed_streams, "#{Views::Frameworks::Explorer::DraftStatus::PUBLISHERS_STREAM}:#{@framework_id}"
      assert_includes subscribed_streams, "framework_activity:#{@framework_id}"
    end
  end

  context "as a tenant admin on a mobile viewport" do
    should "open the binding editor from the kebab" do
      open_binding_editor(size: MOBILE_SIZE)

      # The modal + Turbo Frame body render identically on narrow — the kebab is
      # JS-clicked, the modal is centered — so the editor is reachable on mobile.
      within "#binding-editor" do
        assert_text "Software Engineer"
        assert_selector "select#binding-add-role"
      end
    end
  end
end
