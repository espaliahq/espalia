# frozen_string_literal: true

require "application_system_test_case"

# On-grid focus indication (issue #382).
#
# Explorer focus is set by three different gestures — clicking a category name,
# expanding a capability row, clicking inside an expanded cell — and cleared by
# others. Until now the only signal was the activity pane's title, so the grid
# gave no clue which row or band the feed had narrowed to. `matrix_controller`
# stamps `data-focused` on the focused row / cell / category band and the CSS
# draws a ring; the pane's breadcrumb names the same thing and clears it.
class Frameworks::MatrixFocusRingSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE = [ 375, 812 ].freeze

  FOCUSED_ROW = "tr[data-matrix-target='row'][data-focused='true']"
  FOCUSED_BAND = "tr[data-matrix-target='categoryHeader'][data-focused='true']"

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Focus Ring Framework")

      handler.batch(@framework_id) do
        family_id = SecureRandom.uuid_v7
        role_id = SecureRandom.uuid_v7
        handler.add_role_family(@framework_id, family_id, "Engineering")
        handler.add_role(@framework_id, role_id, family_id, "Software Engineer", "E", "ic")
        handler.add_level(@framework_id, SecureRandom.uuid_v7, role_id, 1, "Engineer I", "E1",
                          is_entry: true)

        @category_id = SecureRandom.uuid_v7
        handler.add_capability_category(@framework_id, @category_id, "Thinking", ordinal: 1)

        @capability_id = SecureRandom.uuid_v7
        handler.add_capability(@framework_id, @capability_id, SecureRandom.uuid_v7, @category_id,
                               "Strategic Thinking")
        handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7,
                                               @capability_id, role_id)
        handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7,
                                            SecureRandom.uuid_v7, @capability_id, 1,
                                            "Asks clarifying questions")
      end

      handler.publish_version(@framework_id, "test")
    end

    sign_in_as(@admin_user)
  end

  [
    { name: "desktop", size: DESKTOP_SIZE },
    { name: "mobile", size: MOBILE_SIZE }
  ].each do |viewport|
    context "the grid focus ring on #{viewport[:name]}" do
      setup do
        page.driver.browser.manage.window.resize_to(*viewport[:size])
        visit edit_framework_path(@framework_id)
        assert_text "Edit mode"
      end

      should "ring the category band when its name is focused, and nothing else" do
        assert_no_selector FOCUSED_BAND, visible: :all
        assert_no_selector FOCUSED_ROW, visible: :all

        focus_category

        assert_selector FOCUSED_BAND, visible: :all
        assert_no_selector FOCUSED_ROW, visible: :all
        # The attribute is only worth stamping if the stylesheet draws it.
        assert_ring_painted "#{FOCUSED_BAND} > td"
      end

      should "move the ring from the band to the row when the row is expanded" do
        focus_category
        assert_selector FOCUSED_BAND, visible: :all

        expand_matrix_row("#capability-row-#{@capability_id}")

        assert_selector "#capability-row-#{@capability_id}[data-focused='true']", visible: :all
        assert_no_selector FOCUSED_BAND, visible: :all
        # A LEVEL cell, not the row's first `<td>`: the sticky capability cell
        # carries `.mx-sticky-edge`'s own box-shadow unconditionally, so probing
        # it would report a ring whether or not one is drawn.
        assert_ring_painted "#{FOCUSED_ROW} > td.mx-cell"
      end

      should "clear the ring when focus returns to the framework" do
        focus_category
        assert_selector FOCUSED_BAND, visible: :all

        # Re-clicking a focused category name toggles it back to framework focus.
        focus_category

        assert_no_selector FOCUSED_BAND, visible: :all
      end
    end
  end

  # The explorer's focus params are hydrated by the context pane, which owns
  # that half of the URL — so without an explorer-side read the pane would show
  # a breadcrumb and a clear × for a focus the grid never marked.
  context "a focus deep link" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "ring the capability it points at, and name it in the pane" do
      visit edit_framework_path(@framework_id, focus: "capability",
                                               capability_id: @capability_id)
      assert_text "Edit mode"

      assert_selector "#capability-row-#{@capability_id}[data-focused='true']", visible: :all
      within("#suggestion-panel") { assert_selector "a[aria-label='Clear focus']" }
    end

    should "ring the category it points at" do
      visit edit_framework_path(@framework_id, focus: "category", category_id: @category_id)
      assert_text "Edit mode"

      assert_selector FOCUSED_BAND, visible: :all
    end
  end

  context "the activity pane's focus breadcrumb" do
    setup do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"
    end

    should "name the focused capability's category and clear focus from the ×" do
      expand_matrix_row("#capability-row-#{@capability_id}")

      within("#suggestion-panel") do
        # The chain the title alone never showed — a focused capability's
        # category — with the clear affordance beside it. Asserted whole and in
        # order: "Thinking" alone is a substring of the capability's own name.
        assert_selector "#framework-activity-focus-breadcrumb",
                        text: "Thinking › Strategic Thinking"
        assert_selector "a[aria-label='Clear focus']"
      end

      assert_selector FOCUSED_ROW, visible: :all

      click_selector_with_js_fallback("a[aria-label='Clear focus']",
                                      expect_text: "All framework activity")

      assert_no_selector FOCUSED_ROW, visible: :all
    end
  end

  private

  # The category name is a `role="button"` span carrying `matrix#focusCategory`;
  # JS-dispatch it, per testing.md's rule for Stimulus-action elements.
  def focus_category
    wait_for_stimulus "matrix"
    # The band lives inside the matrix Turbo Frame, and "Edit mode" in the
    # header does not prove the frame's content has landed — without this wait
    # a slow runner turns a missing element into an opaque Selenium
    # JavascriptError instead of a Capybara timeout.
    assert_selector category_focus_selector, visible: :all
    page.execute_script(<<~JS, @category_id)
      const id = arguments[0];
      const el = document.querySelector(`[data-action*='matrix#focusCategory'][data-category-id='${id}']`);
      if (!el) throw new Error(`no category band for ${id}`);
      el.click();
    JS
  end

  def category_focus_selector
    "[data-action*='matrix#focusCategory'][data-category-id='#{@category_id}']"
  end

  def assert_ring_painted(selector)
    shadow = page.evaluate_script(<<~JS, selector)
      (() => {
        const el = document.querySelector(arguments[0]);
        return el ? getComputedStyle(el).boxShadow : null;
      })()
    JS

    # The ring is drawn `inset`; the sticky column's edge shadow (the only other
    # box-shadow in the grid) is not — so "has a shadow" is not the question,
    # "has an inset one" is.
    assert shadow.present? && shadow.include?("inset"),
           "expected #{selector} to carry the focus ring, got #{shadow.inspect}"
  end
end
