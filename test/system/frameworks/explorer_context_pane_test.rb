# frozen_string_literal: true

require "application_system_test_case"

# System coverage for the framework explorer's context-sensitive right pane —
# now a full activity feed (suggestions are one filter group within it).
#
# Verifies that the feed narrows to match the user's focus context
# (framework / category / capability / cell), that the state round-trips
# through the browser URL, that filter chips switch the visible kinds, and
# that clicking an anchored entry navigates the matrix.
class Frameworks::ExplorerContextPaneTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze

  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    @author_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @person = FactoryBot.create(:person, tenant: @tenant, email: @user.email)
      @author_person = FactoryBot.create(:person, tenant: @tenant, email: @author_user.email)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, role: :admin, person: @person)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @author_user, role: :member, person: @author_person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      @rfid  = SecureRandom.uuid_v7
      @pd_role_id = SecureRandom.uuid_v7
      @eng_role_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, @rfid, "Engineering")
      handler.add_role(@framework_id, @pd_role_id, @rfid, "Product Designer", "PD", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @pd_role_id, 1, "Product Designer I", "PD1", is_entry: true)
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @pd_role_id, 2, "Product Designer II", "PD2")
      handler.add_role(@framework_id, @eng_role_id, @rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @eng_role_id, 1, "Engineer I", "E1", is_entry: true)
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @eng_role_id, 2, "Engineer II", "E2")

      @cat_a_id = SecureRandom.uuid_v7
      @cat_b_id = SecureRandom.uuid_v7
      @cap_a_id = SecureRandom.uuid_v7
      @cap_b_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, @cat_a_id, "Thinking", ordinal: 1)
      handler.add_capability_category(@framework_id, @cat_b_id, "Delivery", ordinal: 2)
      handler.add_capability(@framework_id, @cap_a_id, SecureRandom.uuid_v7, @cat_a_id, "Strategic Thinking")
      handler.add_capability(@framework_id, @cap_b_id, SecureRandom.uuid_v7, @cat_b_id, "Delivery Focus")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_a_id, @pd_role_id)
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_a_id, @eng_role_id)
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_b_id, @pd_role_id)
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_b_id, @eng_role_id)

      @eid_a_l1 = SecureRandom.uuid_v7
      @eid_a_l2 = SecureRandom.uuid_v7
      @eid_b_l1 = SecureRandom.uuid_v7
      handler.set_behavioural_expectation(@framework_id, @eid_a_l1, SecureRandom.uuid_v7, @cap_a_id, 1,
        "Asks clarifying questions")
      handler.set_behavioural_expectation(@framework_id, @eid_a_l2, SecureRandom.uuid_v7, @cap_a_id, 2,
        "Identifies root causes")
      handler.set_behavioural_expectation(@framework_id, @eid_b_l1, SecureRandom.uuid_v7, @cap_b_id, 1,
        "Ships small increments")

      handler.publish_version(@framework_id, "v1")

      handler.add_collaborator(@framework_id, @person.id.to_s, "owner",
                               added_by: @person.id.to_s)
      handler.add_collaborator(@framework_id, @author_person.id.to_s, "collaborator",
                               added_by: @person.id.to_s)

      # Pending suggestions across scopes so we can tell which scope the feed
      # is resolving to at each step. suggest_edit emits an EditSuggested event
      # on the framework stream — the activity feed's source.
      handler.suggest_edit(@framework_id, SecureRandom.uuid_v7,
        "capability", @cap_a_id, "description",
        "SUGG_CAP_A", @author_person.id.to_s, mode: :suggesting)
      handler.suggest_edit(@framework_id, SecureRandom.uuid_v7,
        "capability", @cap_b_id, "description",
        "SUGG_CAP_B", @author_person.id.to_s, mode: :suggesting)
      handler.suggest_edit(@framework_id, SecureRandom.uuid_v7,
        "behavioural_expectation", @eid_a_l1, "description",
        "SUGG_EXP_A_L1", @author_person.id.to_s, mode: :suggesting)
      handler.suggest_edit(@framework_id, SecureRandom.uuid_v7,
        "behavioural_expectation", @eid_a_l2, "description",
        "SUGG_EXP_A_L2", @author_person.id.to_s, mode: :suggesting)
    end

    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@user)
  end

  context "initial feed" do
    should "show all framework activity — suggestions and structural events" do
      visit edit_framework_path(@framework_id)
      open_context_pane

      within "#suggestion-panel" do
        assert_text "All framework activity"
        assert_text "SUGG_CAP_A"
        assert_text "SUGG_CAP_B"
        # Structural lifecycle entries surface too — not just suggestions.
        assert_text "Added a capability"
        assert_text "Published v1"
      end
    end
  end

  context "capability focus" do
    should "narrow the feed to the expanded capability" do
      visit edit_framework_path(@framework_id)
      open_context_pane

      wait_for_stimulus "matrix"
      page.execute_script(<<~JS)
        document.querySelector("tr[data-capability-id='#{@cap_a_id}']")?.click();
      JS

      within "#suggestion-panel" do
        assert_text "Strategic Thinking"
        assert_text "SUGG_CAP_A"
        assert_text "SUGG_EXP_A_L1"
        assert_no_text "SUGG_CAP_B"
      end

      assert_match(/focus=capability/, page.current_url)
      assert_match(/capability_id=#{@cap_a_id}/, page.current_url)
    end
  end

  context "cell focus" do
    should "title the feed for the focused cell, scoped to the capability" do
      visit edit_framework_path(@framework_id)
      open_context_pane

      wait_for_stimulus "matrix"
      page.execute_script(<<~JS)
        document.querySelector("tr[data-capability-id='#{@cap_a_id}']")?.click();
      JS
      page.execute_script(<<~JS)
        document.querySelector("td[data-action='click->matrix#focusCell'][data-level-ordinal='2']")?.click();
      JS

      within "#suggestion-panel" do
        assert_text "× L2"
        assert_text "SUGG_EXP_A_L2"
        assert_no_text "SUGG_CAP_B"
      end

      assert_match(/level_ordinal=2/, page.current_url)
    end
  end

  context "category focus" do
    should "focus a category when the category name is clicked" do
      visit edit_framework_path(@framework_id)
      open_context_pane

      wait_for_stimulus "matrix"
      page.execute_script(<<~JS)
        document.querySelector("[data-action='click->matrix#focusCategory'][data-category-id='#{@cat_a_id}']")?.click();
      JS

      within "#suggestion-panel" do
        assert_text "Thinking — category"
        assert_text "SUGG_CAP_A"
        assert_text "SUGG_EXP_A_L1"
        assert_no_text "SUGG_CAP_B"
      end

      assert_match(/focus=category/, page.current_url)
      assert_match(/category_id=#{@cat_a_id}/, page.current_url)
    end

    should "collapse category rows via the chevron without changing focus" do
      visit edit_framework_path(@framework_id)
      wait_for_stimulus "matrix"

      chevron_selector = "[data-matrix-target='categoryHeader'][data-category-id='#{@cat_a_id}'] " \
        "button[data-action='click->matrix#toggleCategory']"
      row_selector = "tr[data-capability-id='#{@cap_a_id}']"

      collapse_js = "document.querySelector(#{chevron_selector.to_json})?.click();"
      page.execute_script(collapse_js)
      unless page.has_no_css?(row_selector, visible: true, wait: 5)
        page.execute_script(collapse_js)
      end

      assert_no_selector row_selector, visible: true, wait: 5
      refute_match(/focus=/, page.current_url)
    end
  end

  context "filter chips" do
    should "switch the visible entry kinds client-side" do
      visit edit_framework_path(@framework_id)
      open_context_pane

      within "#suggestion-panel" do
        assert_text "SUGG_CAP_A"
        assert_text "Added a capability"

        # Structural-only: suggestions drop, capability adds remain.
        click_button "Structural"
        assert_text "Added a capability"
        assert_no_text "SUGG_CAP_A"

        # Suggestions-only: the inverse.
        click_button "Suggestions"
        assert_text "SUGG_CAP_A"
        assert_no_text "Added a capability"
      end
    end
  end

  context "show-all clear" do
    should "return to framework scope and collapse expanded rows" do
      visit edit_framework_path(@framework_id)
      open_context_pane

      page.execute_script(<<~JS)
        document.querySelector("#suggestion-panel [data-nav-capability-id='#{@cap_a_id}']")?.click();
      JS

      assert_selector "tr[data-matrix-target='expandedRow'][data-capability-id='#{@cap_a_id}']",
                       visible: true

      # Show-all clears focus via a Turbo Frame navigation — JS-fallback the
      # click so a starved-CI pointer drop doesn't leave the pane focused.
      click_link_with_js_fallback("Show all framework activity", expect_text: "All framework activity")

      within "#suggestion-panel" do
        assert_text "SUGG_CAP_B"
      end

      assert_no_selector "tr[data-matrix-target='expandedRow'][data-capability-id='#{@cap_a_id}']",
                          visible: true
    end
  end

  context "deep link" do
    should "restore capability focus from URL params" do
      visit edit_framework_path(@framework_id,
        focus: "capability", capability_id: @cap_a_id)
      open_context_pane

      within "#suggestion-panel" do
        assert_text "Strategic Thinking"
        assert_text "SUGG_CAP_A"
        assert_no_text "SUGG_CAP_B"
      end
    end
  end

  context "entry navigation" do
    should "expand the capability row in the matrix when clicking an anchored entry" do
      visit edit_framework_path(@framework_id)
      open_context_pane

      page.execute_script(<<~JS)
        document.querySelector("#suggestion-panel [data-nav-capability-id='#{@cap_a_id}']")?.click();
      JS

      assert_selector "tr[data-matrix-target='expandedRow'][data-capability-id='#{@cap_a_id}']",
                       visible: true
    end
  end

  private

  def open_context_pane
    toggle_context_pane
  end
end
