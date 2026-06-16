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
      role_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, role_id, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, role_id, 1, "Engineer I", "E1", is_entry: true)

      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_id, role_id)
      handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
        @cap_id, 1, "Asks clarifying questions")
      handler.publish_version(@framework_id, "v1")

      handler.add_collaborator(@framework_id, @owner.id.to_s, "owner", added_by: @owner.id.to_s)
      handler.add_collaborator(@framework_id, @collaborator.id.to_s, "collaborator", added_by: @owner.id.to_s)

      @sugg_id = SecureRandom.uuid_v7
      handler.suggest_edit(@framework_id, @sugg_id, "capability", @cap_id, "description",
        "A sharper capability description", @collaborator.id.to_s, mode: :suggesting)
    end

    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
  end

  def suggestion
    FrameworkState::SuggestedEdit.find_by(suggestion_id: @sugg_id)
  end

  # Polls the read model so an async approve/reject POST has provably persisted
  # before we assert on a freshly-rendered page (race-free, no cable dependence).
  def wait_for_status(status)
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.1 until suggestion&.status == status
    end
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

      page.execute_script(
        "document.querySelector(\"[data-suggestion-action-approve-url-value*='#{@sugg_id}'] " \
        "button[data-action='suggestion-action#approve']\").click()"
      )

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

    should "reject a suggestion via the modal with an optional reason" do
      visit edit_framework_path(@framework_id)
      toggle_context_pane

      page.execute_script(
        "document.querySelector(\"#suggestion-panel button[data-modal-target-id='reject-suggestion-modal']\").click()"
      )
      assert_selector "#reject-suggestion-modal", visible: true
      fill_in "reject_reason", with: "Not aligned with the level framing"
      click_button "Reject suggestion"

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
  end
end
