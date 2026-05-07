# frozen_string_literal: true

require "application_system_test_case"

# System coverage for the framework explorer's context-sensitive right pane.
#
# Verifies that the suggestion panel narrows to match the user's focus
# context (framework / category / capability / cell) and combines with
# role selection, and that the state round-trips through the browser URL.
class Frameworks::ExplorerContextPaneTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

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

      @ill_pd_a_l1 = SecureRandom.uuid_v7
      @ill_eng_a_l1 = SecureRandom.uuid_v7
      handler.add_role_illustration(@framework_id, @ill_pd_a_l1, SecureRandom.uuid_v7, @eid_a_l1, @pd_role_id, 1,
        "Runs user research sessions")
      handler.add_role_illustration(@framework_id, @ill_eng_a_l1, SecureRandom.uuid_v7, @eid_a_l1, @eng_role_id, 1,
        "Reviews technical requirements")

      handler.publish_version(@framework_id, "v1")

      # Collaborators so that the author can file suggestions.
      handler.add_collaborator(@framework_id, @person.id.to_s, "owner",
                               added_by: @person.id.to_s)
      handler.add_collaborator(@framework_id, @author_person.id.to_s, "collaborator",
                               added_by: @person.id.to_s)

      # Seed pending suggestions in four flavours so we can tell which scope
      # the panel is resolving to at each step.
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
      handler.suggest_edit(@framework_id, SecureRandom.uuid_v7,
        "role_illustration", @ill_pd_a_l1, "description",
        "SUGG_ILL_PD", @author_person.id.to_s, mode: :suggesting)
      handler.suggest_edit(@framework_id, SecureRandom.uuid_v7,
        "role_illustration", @ill_eng_a_l1, "description",
        "SUGG_ILL_ENG", @author_person.id.to_s, mode: :suggesting)
    end

    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@user)
  end

  context "initial panel" do
    should "show all framework suggestions when the pane is opened with no focus" do
      visit edit_framework_path(@framework_id)
      open_context_pane

      within "#suggestion-panel" do
        assert_text "All framework suggestions"
        assert_text "SUGG_CAP_A"
        assert_text "SUGG_CAP_B"
        assert_text "SUGG_EXP_A_L1"
      end
    end
  end

  context "capability focus" do
    should "narrow panel to the expanded capability" do
      visit edit_framework_path(@framework_id)
      open_context_pane

      wait_for_stimulus "matrix"
      # JS-dispatch the row click — Capybara's pointer click on the row
      # has been silently dropped on starved CI runners, leaving the
      # suggestion panel un-filtered.
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
    should "narrow panel to a single capability \u00d7 level cell" do
      visit edit_framework_path(@framework_id)
      open_context_pane

      wait_for_stimulus "matrix"
      # JS-dispatch both row + cell clicks \u2014 Capybara's pointer click on
      # rows is occasionally dropped on starved CI runners.
      page.execute_script(<<~JS)
        document.querySelector("tr[data-capability-id='#{@cap_a_id}']")?.click();
      JS

      # Click an expanded-row cell to focus it. The expanded <td> carries the
      # focusCell action + capability_id + level_ordinal data attributes.
      page.execute_script(<<~JS)
        document.querySelector("td[data-action='click->matrix#focusCell'][data-level-ordinal='2']")?.click();
      JS

      within "#suggestion-panel" do
        assert_text "\u00d7 L2"
        assert_text "SUGG_EXP_A_L2"
        assert_no_text "SUGG_EXP_A_L1"
      end

      assert_match(/level_ordinal=2/, page.current_url)
    end
  end

  context "category focus" do
    should "focus a category when the category name is clicked" do
      visit edit_framework_path(@framework_id)
      open_context_pane

      wait_for_stimulus "matrix"
      find("[data-action='click->matrix#focusCategory'][data-category-id='#{@cat_a_id}']").click

      within "#suggestion-panel" do
        assert_text "Thinking \u2014 category"
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

      # Collapse via the chevron button — retry once if the click is lost on
      # slow CI runners (the row stays visible).
      find(chevron_selector).click
      unless page.has_no_css?(row_selector, visible: true, wait: 5)
        find(chevron_selector).click
      end

      # Capability rows for cat_a are now hidden
      assert_no_selector row_selector, visible: true, wait: 5

      # Browser URL should not have focus params
      refute_match(/focus=/, page.current_url)
    end
  end

  context "show-all clear" do
    should "return to framework scope and collapse expanded rows" do
      visit edit_framework_path(@framework_id)
      open_context_pane

      # Navigate to a capability via suggestion click to expand the row
      within "#suggestion-panel" do
        find("[data-nav-capability-id='#{@cap_a_id}']", match: :first).click
      end

      # Row should be expanded
      assert_selector "tr[data-matrix-target='expandedRow'][data-capability-id='#{@cap_a_id}']",
                       visible: true

      within "#suggestion-panel" do
        click_link "Show all framework suggestions"
      end

      within "#suggestion-panel" do
        assert_text "All framework suggestions"
        assert_text "SUGG_CAP_B"
      end

      # Matrix should have collapsed back
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

  context "context labels" do
    should "show full role and level for illustration suggestions" do
      visit edit_framework_path(@framework_id,
        focus: "capability", capability_id: @cap_a_id)
      open_context_pane

      within "#suggestion-panel" do
        # Illustration rows show "Role Name · Level Title" on their own line
        assert_text "Product Designer \u00b7 Product Designer I"
        assert_text "Software Engineer \u00b7 Engineer I"
      end
    end

    should "show capability and level for expectation suggestions" do
      visit edit_framework_path(@framework_id)
      open_context_pane

      within "#suggestion-panel" do
        # Expectation rows show "Capability Name · Level N"
        assert_text "Strategic Thinking \u00b7 Level 1"
        assert_text "Strategic Thinking \u00b7 Level 2"
      end
    end

    should "show entity type and kind badges without tiers" do
      visit edit_framework_path(@framework_id)
      open_context_pane

      within "#suggestion-panel" do
        assert_text "Illustration"
        assert_text "Expectation"
        assert_text "Edit"
        # Tier badges should not appear
        assert_no_text "T1"
        assert_no_text "T2"
        assert_no_text "T3"
      end
    end
  end

  context "suggestion row navigation" do
    should "expand the capability row in the matrix when clicking an illustration suggestion" do
      visit edit_framework_path(@framework_id)
      open_context_pane

      within "#suggestion-panel" do
        # Click the suggestion body (not the detail link) for an illustration
        find("[data-nav-capability-id='#{@cap_a_id}']", match: :first).click
      end

      # The matrix should expand the matching capability row
      assert_selector "tr[data-matrix-target='expandedRow'][data-capability-id='#{@cap_a_id}']",
                       visible: true
    end

    should "provide a separate detail link to the suggestion page" do
      visit edit_framework_path(@framework_id)
      open_context_pane

      within "#suggestion-panel" do
        # The detail link (arrow icon) should navigate to the suggestion detail page
        assert_selector "a[title='View suggestion details']", visible: :all
      end
    end
  end

  context "role filter combined with focus" do
    should "drop role_illustration rows outside selected roles" do
      # Select only PD — engineering illustration should drop from panel.
      visit edit_framework_path(@framework_id,
        focus: "capability", capability_id: @cap_a_id, roles: [ @pd_role_id ])
      open_context_pane

      within "#suggestion-panel" do
        assert_text "SUGG_ILL_PD"
        assert_no_text "SUGG_ILL_ENG"
        # Expectation + capability suggestions stay regardless of role filter
        assert_text "SUGG_EXP_A_L1"
      end
    end
  end

  private

  def open_context_pane
    toggle_context_pane
  end
end
