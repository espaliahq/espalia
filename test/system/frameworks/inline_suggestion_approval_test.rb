# frozen_string_literal: true

require "application_system_test_case"

# System coverage for inline suggestion approval from the framework activity
# feed (the "actionable feed entry" pattern):
#
# - a reviewer with tier authority sees Approve / Reject on a pending entry;
#   a suggest-only collaborator sees neither;
# - one-click Approve persists and the entry resolves;
# - Reject opens the shared modal, takes an optional reason, and persists it.
class Frameworks::InlineSuggestionApprovalTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  setup do
    @tenant = FactoryBot.create(:tenant)
    @owner_user = FactoryBot.create(:user, password: "password123")
    @collaborator_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @owner = FactoryBot.create(:person, tenant: @tenant, email: @owner_user.email)
      @collaborator = FactoryBot.create(:person, tenant: @tenant, email: @collaborator_user.email)
      # Owner is also tenant admin → approval authority on every tier.
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @owner_user, role: :admin, person: @owner)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @collaborator_user, role: :member, person: @collaborator)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, @role_id, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @role_id, 1, "Engineer I", "E1", is_entry: true)

      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @exp_id = SecureRandom.uuid_v7
      @ill_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_id, @role_id)
      handler.set_behavioural_expectation(@framework_id, @exp_id, SecureRandom.uuid_v7,
        @cap_id, 1, "Asks clarifying questions")
      handler.add_role_illustration(@framework_id, @ill_id, SecureRandom.uuid_v7,
        @exp_id, @role_id, 1, "Raises risks in stand-up")
      handler.publish_version(@framework_id, "v1")

      handler.add_collaborator(@framework_id, @owner.id.to_s, "owner", added_by: @owner.id.to_s)
      handler.add_collaborator(@framework_id, @collaborator.id.to_s, "collaborator", added_by: @owner.id.to_s)

      @sugg_id = SecureRandom.uuid_v7
      handler.suggest_edit(@framework_id, @sugg_id, "capability", @cap_id, "description",
        "A sharper capability description", @collaborator.id.to_s, mode: :suggesting)
    end

    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
  end

  def suggestion(id = @sugg_id)
    FrameworkState::SuggestedEdit.find_by(suggestion_id: id)
  end

  # Polls the read model so an async approve/reject POST has provably persisted
  # before we assert on a freshly-rendered page (race-free, no cable dependence).
  def wait_for_status(status, id = @sugg_id)
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.1 until suggestion(id)&.status == status
    end
  end

  # Scroll restore runs on turbo:frame-load, which fires a beat AFTER the
  # fresh frame content becomes visible — an immediate read can catch the
  # pre-restore scrollTop of 0. Poll until the restore lands (or time out and
  # return the last value for the failure message).
  def wait_for_scroll_restore(minimum)
    scroll_top = 0
    Timeout.timeout(Capybara.default_max_wait_time) do
      loop do
        scroll_top = page.evaluate_script(
          "document.querySelector(\"[data-context-pane-target='scroller']\").scrollTop"
        )
        return scroll_top if scroll_top >= minimum

        sleep 0.1
      end
    end
  rescue Timeout::Error
    scroll_top
  end

  # A pending edit on the expectation / illustration, created per-test so the
  # shared feed assertions (single pending suggestion) stay valid.
  def suggest_expectation_edit
    id = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      Frameworks::CommandHandler.new.suggest_edit(@framework_id, id,
        "behavioural_expectation", @exp_id, "description",
        "Asks sharper clarifying questions", @collaborator.id.to_s, mode: :suggesting)
    end
    id
  end

  def suggest_illustration_edit
    id = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      Frameworks::CommandHandler.new.suggest_edit(@framework_id, id,
        "role_illustration", @ill_id, "description",
        "Raises risks early and in writing", @collaborator.id.to_s, mode: :suggesting)
    end
    id
  end

  # A pending NEW illustration (create suggestion) — renders as a ghost entry.
  def suggest_illustration_create
    id = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      Frameworks::CommandHandler.new.suggest_create(@framework_id, id,
        "role_illustration",
        { "role_id" => @role_id, "description" => "Shares a written risk log weekly" },
        parent_id: @exp_id, author_id: @collaborator.id.to_s, mode: :suggesting)
    end
    id
  end

  context "as a reviewer with tier authority (owner + admin)" do
    setup { sign_in_as(@owner_user) }

    should "show Approve and Reject on a pending suggestion entry" do
      visit edit_framework_path(@framework_id)
      toggle_context_pane

      within "#suggestion-panel" do
        assert_text "Suggested an edit to capability"
        assert_selector "button", text: "Approve"
        assert_selector "button", text: "Reject"
      end
    end

    should "approve a suggestion in one click and persist it" do
      visit edit_framework_path(@framework_id)
      toggle_context_pane
      assert_selector "#suggestion-panel button", text: "Approve"

      # Neutralise the broadcast-driven frame reload for this test: the point
      # is that the resolved marker appears WITHOUT it (instant local
      # feedback), and on a loaded runner the reload can otherwise replace
      # the marker before the assertion polls it.
      page.execute_script("document.querySelector('#suggestion-panel').reload = () => {}")
      page.execute_script(
        "document.querySelector(\"[data-suggestion-action-approve-url-value*='#{@sugg_id}'] " \
        "button[data-action='suggestion-action#approve']\").click()"
      )

      # Instant local feedback: the action row swaps to its resolved state the
      # moment the POST succeeds — no feed reload involved (stubbed above).
      assert_text "✓ Approved"

      wait_for_status("approved")

      # Re-render proves the resolution: the entry is no longer actionable and a
      # resolution entry has appeared.
      visit edit_framework_path(@framework_id)
      toggle_context_pane
      within "#suggestion-panel" do
        assert_text "Approved a capability suggestion"
        assert_no_selector "button", text: "Approve"
      end
    end

    should "mark the grid kebab terminal when the suggestion resolves from the feed" do
      visit edit_framework_path(@framework_id)
      toggle_context_pane
      assert_selector "#suggestion-panel button", text: "Approve"

      page.execute_script(
        "document.querySelector(\"[data-suggestion-action-approve-url-value*='#{@sugg_id}'] " \
        "button[data-action='suggestion-action#approve']\").click()"
      )
      wait_for_status("approved")

      # The row kebab lives OUTSIDE the surgically-replaced frame and survives
      # the resolution — its items must go terminal (approve relabelled, both
      # disabled), never linger actionable against a resolved suggestion.
      page.execute_script(
        "document.querySelector(\"tr[data-capability-id='#{@cap_id}'] " \
        "button[data-dropdown-target='trigger']\").click()"
      )
      assert_selector "tr[data-capability-id='#{@cap_id}'] button[role='menuitem'][disabled]",
                      text: "✓ Approved"
      assert_selector "tr[data-capability-id='#{@cap_id}'] button[role='menuitem'][disabled]",
                      text: "Reject description change"
    end

    should "approve a capability edit from the matrix row kebab" do
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      assert_selector "tr[data-capability-id='#{@cap_id}']"

      # Open the row-actions dropdown, then approve the pending description edit.
      page.execute_script(
        "document.querySelector(\"tr[data-capability-id='#{@cap_id}'] " \
        "button[data-dropdown-target='trigger']\").click()"
      )
      assert_text "Approve description change"
      page.execute_script(
        "document.querySelector(\"tr[data-capability-id='#{@cap_id}'] " \
        "button[data-action='suggestion-action#approve']\").click()"
      )

      wait_for_status("approved")
      assert_equal "A sharper capability description",
                   FrameworkState::Capability.find_by(capability_id: @cap_id).description
    end

    should "approve an expectation edit from the cell kebab" do
      exp_sugg_id = suggest_expectation_edit
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      assert_selector "tr[data-capability-id='#{@cap_id}']"

      # The cell kebab is the row's second dropdown (after the row-actions one).
      page.execute_script(
        "document.querySelectorAll(\"tr[data-capability-id='#{@cap_id}'] " \
        "button[data-dropdown-target='trigger']\")[1].click()"
      )
      assert_text "Approve expectation change"
      page.execute_script(
        "document.querySelector(\"[data-suggestion-action-approve-url-value*='#{exp_sugg_id}'] " \
        "button[data-action='suggestion-action#approve']\").click()"
      )

      wait_for_status("approved", exp_sugg_id)
      assert_equal "Asks sharper clarifying questions",
                   FrameworkState::BehaviouralExpectation.find_by(expectation_id: @exp_id).description
    end

    should "approve an expectation edit from the cell kebab at the mobile viewport" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      exp_sugg_id = suggest_expectation_edit
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      assert_selector "tr[data-capability-id='#{@cap_id}']"

      # Touch devices have no hover — the trigger stays visible via
      # pointer-coarse:opacity-100 and the same JS click path applies.
      page.execute_script(
        "document.querySelectorAll(\"tr[data-capability-id='#{@cap_id}'] " \
        "button[data-dropdown-target='trigger']\")[1].click()"
      )
      assert_text "Approve expectation change"
      page.execute_script(
        "document.querySelector(\"[data-suggestion-action-approve-url-value*='#{exp_sugg_id}'] " \
        "button[data-action='suggestion-action#approve']\").click()"
      )

      wait_for_status("approved", exp_sugg_id)
      assert_equal "Asks sharper clarifying questions",
                   FrameworkState::BehaviouralExpectation.find_by(expectation_id: @exp_id).description
    end

    should "approve an illustration edit from the illustration kebab" do
      ill_sugg_id = suggest_illustration_edit
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      expand_matrix_row("tr[data-capability-id='#{@cap_id}']")

      page.execute_script(
        "document.querySelector(\"#illustration-#{@ill_id} " \
        "button[data-dropdown-target='trigger']\").click()"
      )
      assert_text "Approve illustration change"
      # Archive lives in the same kebab — the menu is the illustration's
      # single "more actions" home.
      assert_text "Archive…"
      page.execute_script(
        "document.querySelector(\"[data-suggestion-action-approve-url-value*='#{ill_sugg_id}'] " \
        "button[data-action='suggestion-action#approve']\").click()"
      )

      wait_for_status("approved", ill_sugg_id)
      assert_equal "Raises risks early and in writing",
                   FrameworkState::RoleIllustration.find_by(illustration_id: @ill_id).description
    end

    should "approve a NEW illustration from its ghost kebab" do
      create_sugg_id = suggest_illustration_create
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      expand_matrix_row("tr[data-capability-id='#{@cap_id}']")

      page.execute_script(
        "document.querySelector(\"turbo-frame[id='pending-suggestion-#{create_sugg_id}'] " \
        "button[data-dropdown-target='trigger']\").click()"
      )
      assert_text "Approve new illustration"
      page.execute_script(
        "document.querySelector(\"[data-suggestion-action-approve-url-value*='#{create_sugg_id}'] " \
        "button[data-action='suggestion-action#approve']\").click()"
      )

      wait_for_status("approved", create_sugg_id)
      assert FrameworkState::RoleIllustration.exists?(description: "Shares a written risk log weekly"),
             "approving the create should apply the new illustration"
    end

    should "reject a NEW illustration from its ghost kebab via the shared modal" do
      create_sugg_id = suggest_illustration_create
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      expand_matrix_row("tr[data-capability-id='#{@cap_id}']")

      page.execute_script(
        "document.querySelector(\"button[data-reject-suggestion-id='#{create_sugg_id}']\").click()"
      )
      assert_selector "#reject-suggestion-modal", visible: true
      fill_in "reject_reason", with: "Covered by the existing example"
      click_button_with_js_fallback "Reject suggestion", expect_no_text: "Reject suggestion"

      wait_for_status("rejected", create_sugg_id)
      assert_not FrameworkState::RoleIllustration.exists?(description: "Shares a written risk log weekly"),
                 "rejecting the create must not apply the illustration"
    end

    should "approve an illustration edit from its kebab at the mobile viewport" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      ill_sugg_id = suggest_illustration_edit
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      expand_matrix_row("tr[data-capability-id='#{@cap_id}']")

      page.execute_script(
        "document.querySelector(\"#illustration-#{@ill_id} " \
        "button[data-dropdown-target='trigger']\").click()"
      )
      assert_text "Approve illustration change"
      page.execute_script(
        "document.querySelector(\"[data-suggestion-action-approve-url-value*='#{ill_sugg_id}'] " \
        "button[data-action='suggestion-action#approve']\").click()"
      )

      wait_for_status("approved", ill_sugg_id)
      assert_equal "Raises risks early and in writing",
                   FrameworkState::RoleIllustration.find_by(illustration_id: @ill_id).description
    end

    should "reject an expectation edit from the cell kebab via the shared modal" do
      exp_sugg_id = suggest_expectation_edit
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      assert_selector "tr[data-capability-id='#{@cap_id}']"

      page.execute_script(
        "document.querySelector(\"button[data-reject-suggestion-id='#{exp_sugg_id}']\").click()"
      )
      assert_selector "#reject-suggestion-modal", visible: true
      fill_in "reject_reason", with: "Keep the published phrasing"
      click_button_with_js_fallback "Reject suggestion", expect_no_text: "Reject suggestion"

      wait_for_status("rejected", exp_sugg_id)
      assert_equal "Asks clarifying questions",
                   FrameworkState::BehaviouralExpectation.find_by(expectation_id: @exp_id).description
    end

    should "keep the feed's scroll position across the post-approval reload" do
      # Enough feed entries to make the pane scroll (each category add is one
      # structural entry).
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        22.times do |i|
          handler.add_capability_category(@framework_id, SecureRandom.uuid_v7,
            "Filler Category #{i}", ordinal: 10 + i)
        end
      end

      visit edit_framework_path(@framework_id)
      toggle_context_pane
      assert_selector "#suggestion-panel button", text: "Approve"

      scrolled_to = page.evaluate_script(<<~JS)
        (() => {
          const s = document.querySelector("[data-context-pane-target='scroller']");
          s.scrollTop = 400;
          return s.scrollTop;
        })()
      JS
      # ≥200 (not just >0): with a barely-overflowing feed, clamping could
      # make the restore assertion pass vacuously even after a reset-to-top
      # regression.
      assert_operator scrolled_to, :>=, 200, "feed must overflow well past the tolerance band"

      page.execute_script(
        "document.querySelector(\"[data-suggestion-action-approve-url-value*='#{@sugg_id}'] " \
        "button[data-action='suggestion-action#approve']\").click()"
      )
      wait_for_status("approved")
      # The broadcast reload has landed once the canonical resolution entry
      # renders in the feed.
      within "#suggestion-panel" do
        assert_text "Approved a capability suggestion"
      end

      restored = wait_for_scroll_restore(scrolled_to - 100)
      assert_operator restored, :>=, scrolled_to - 100,
        "the reload must restore the reviewer's scroll position, not reset to the top"
    end

    should "land on the exact pending example when its feed entry is clicked" do
      create_sugg_id = suggest_illustration_create
      visit edit_framework_path(@framework_id)
      toggle_context_pane
      within "#suggestion-panel" do
        assert_text "Proposed a new illustration"
      end

      # Click the entry body (not its action buttons) — dispatches
      # suggestion:navigate with the suggestion id.
      page.execute_script(
        "document.querySelector(\"#suggestion-panel li[data-nav-suggestion-id='#{create_sugg_id}']\").click()"
      )

      # The row expands AND the ghost's decorated element itself is flagged as
      # the navigation target — not just the cell's vicinity.
      assert_selector "turbo-frame#pending-suggestion-#{create_sugg_id} .suggestion-nav-highlight",
                      visible: :all
    end

    should "fall back to the cell when the entry's suggestion has no on-grid anchor" do
      exp_sugg_id = suggest_expectation_edit
      visit edit_framework_path(@framework_id)
      toggle_context_pane
      within "#suggestion-panel" do
        assert_text "Suggested an edit to expectation"
      end

      # Remove the squiggle anchor to simulate a decoration that isn't
      # rendered (e.g. the suggestion's role filtered out of the view).
      page.execute_script(
        "document.querySelectorAll(\"#framework-matrix [data-suggestion-id='#{exp_sugg_id}']\")" \
        ".forEach(el => el.removeAttribute('data-suggestion-id'))"
      )
      page.execute_script(
        "document.querySelector(\"#suggestion-panel li[data-nav-suggestion-id='#{exp_sugg_id}']\").click()"
      )

      # The cell itself carries the highlight instead.
      assert_selector "td.suggestion-nav-highlight", visible: :all
    end

    should "return to the reviewer's place in the feed after a click-through detour" do
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        22.times do |i|
          handler.add_capability_category(@framework_id, SecureRandom.uuid_v7,
            "Filler Category #{i}", ordinal: 10 + i)
        end
      end

      visit edit_framework_path(@framework_id)
      toggle_context_pane
      within "#suggestion-panel" do
        assert_text "Suggested an edit to capability"
      end

      scrolled_to = page.evaluate_script(<<~JS)
        (() => {
          const s = document.querySelector("[data-context-pane-target='scroller']");
          s.scrollTop = 400;
          return s.scrollTop;
        })()
      JS
      assert_operator scrolled_to, :>=, 200, "feed must overflow well past the tolerance band"

      # Click-through: navigate to the suggestion's entity — the feed narrows
      # to that capability's activity.
      page.execute_script(
        "document.querySelector(\"#suggestion-panel li[data-nav-suggestion-id='#{@sugg_id}']\").click()"
      )
      within "#suggestion-panel" do
        assert_text "← Show all framework activity"
      end

      # Return to the full feed — the reviewer lands back at the entry they
      # left from, not at the top.
      page.execute_script(
        "document.querySelector(\"#suggestion-panel a[data-action*='clearFocus']\").click()"
      )
      within "#suggestion-panel" do
        assert_no_text "← Show all framework activity"
      end

      restored = wait_for_scroll_restore(scrolled_to - 100)
      assert_operator restored, :>=, scrolled_to - 100,
        "returning to the feed must restore the reviewer's place, not reset to the top"
    end

    should "reject a suggestion via the modal with an optional reason" do
      visit edit_framework_path(@framework_id)
      toggle_context_pane

      # The feed frame renders asynchronously — the button must exist before
      # the JS click, or querySelector returns null on a starved runner.
      assert_selector "#suggestion-panel button[data-modal-target-id='reject-suggestion-modal']", visible: :all
      page.execute_script(
        "document.querySelector(\"#suggestion-panel button[data-modal-target-id='reject-suggestion-modal']\").click()"
      )
      assert_selector "#reject-suggestion-modal", visible: true
      fill_in "reject_reason", with: "Not aligned with the level framing"
      # Neutralise the broadcast reload so the transient local marker can't be
      # replaced by the canonical feed entry before the assertion polls it.
      page.execute_script("document.querySelector('#suggestion-panel').reload = () => {}")
      click_button_with_js_fallback "Reject suggestion", expect_no_text: "Reject suggestion"

      # The rejected entry's action row swaps to its resolved state in place —
      # the modal's dispatch carries the suggestion id (instant feedback, no
      # feed reload involved).
      assert_text "✓ Rejected"

      wait_for_status("rejected")

      visit edit_framework_path(@framework_id)
      toggle_context_pane
      within "#suggestion-panel" do
        assert_text "Rejected a capability suggestion"
        assert_text "Not aligned with the level framing"
        assert_no_selector "button", text: "Approve"
      end
    end
  end

  context "as a suggest-only collaborator (no approval authority)" do
    setup { sign_in_as(@collaborator_user) }

    should "see the feed entry but no Approve / Reject controls" do
      visit edit_framework_path(@framework_id)
      toggle_context_pane

      within "#suggestion-panel" do
        assert_text "Suggested an edit to capability"
        assert_no_selector "button", text: "Approve"
        assert_no_selector "button", text: "Reject"
      end
    end

    should "get no approval kebab on expectation cells, illustrations, or ghosts" do
      exp_sugg_id = suggest_expectation_edit
      ill_sugg_id = suggest_illustration_edit
      create_sugg_id = suggest_illustration_create
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"
      assert_selector "tr[data-capability-id='#{@cap_id}']"

      [ exp_sugg_id, ill_sugg_id, create_sugg_id ].each do |sid|
        # The approve URL rides the kebab items' wrapper mount, not the button.
        assert_no_selector "[data-suggestion-action-approve-url-value*='#{sid}']",
                           visible: :all
        assert_no_selector "button[data-reject-suggestion-id='#{sid}']", visible: :all
      end
    end
  end
end
