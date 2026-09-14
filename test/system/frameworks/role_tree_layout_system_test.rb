# frozen_string_literal: true

require "application_system_test_case"

# The role tree's row layout (#384 follow-up, reported from the field).
#
# Almost every real role and family name wrapped onto two lines — "Commercial
# Finance", "Analytics Engineer", "Product Management" — making the tree twice
# as tall as it needed to be and hard to scan. Not because the names were long:
# because the row reserved width for controls that were not visible. §11a's own
# trap, one pane to the left of where it was written: `opacity: 0` still takes
# layout space, and the solo pill + rename pencil + ⋮ took ~90 px off a ~190 px
# slot.
#
# The fix has two halves and this pins both:
#
#  - the hover controls float over the right edge of the name's box, so they
#    reserve nothing;
#  - the pane is wide enough that the seeded framework's longest names clear
#    their box with room to spare.
#
# Names are never truncated — `break-words` remains the fallback for a name
# longer than any pane would hold — so "one line" is the assertion, not
# "no ellipsis".
class Frameworks::RoleTreeLayoutSystemTest < ApplicationSystemTestCase
  # Names of the shape the report named. The longest here ("Software
  # Engineering", "Engineering Manager") are within a pixel of the longest in
  # the real seeded framework, so the headroom this test proves is the
  # headroom production has.
  FAMILIES = [ "Software Engineering", "Commercial Finance", "Product Management" ].freeze
  ROLES = [ "Engineering Manager", "Analytics Engineer", "Financial Controller" ].freeze

  # One round trip: how each name box is laid out, and whether its text needed
  # more than one line box to render.
  TREE_PROBE_JS = <<~JS
    (() => {
      const px = (n) => Math.round(n * 10) / 10;
      const read = (selector) =>
        [...document.querySelectorAll(selector)].map((span) => {
          const slot = span.closest(".relative");
          const actions = slot ? slot.querySelector(".tree-actions") : null;
          return {
            name: span.textContent.trim(),
            lines: span.getClientRects().length,
            slotWidth: slot ? px(slot.getBoundingClientRect().width) : null,
            slotRight: slot ? px(slot.getBoundingClientRect().right) : null,
            actionsPosition: actions ? getComputedStyle(actions).position : null,
            actionsRight: actions ? px(actions.getBoundingClientRect().right) : null
          };
        });

      return {
        roles: read("[data-tree-target='role'] turbo-frame[id^='role-name-'] span"),
        families: read("turbo-frame[id^='role-family-name-'] span")
      };
    })()
  JS

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Tree Layout Framework")
      FAMILIES.each_with_index do |family_name, family_index|
        rfid = SecureRandom.uuid_v7
        handler.add_role_family(@framework_id, rfid, family_name, department: "Everything")
        rid = SecureRandom.uuid_v7
        handler.add_role(@framework_id, rid, rfid, ROLES[family_index], "R#{family_index}", "ic")
        handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1,
                          "Level One", "R#{family_index}1", is_entry: true)
        next unless family_index.zero?

        @role_id = rid
        handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
        handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
        handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, rid)
        handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                            cap_id, 1, "Asks clarifying questions")
      end
      handler.publish_version(@framework_id, "test")
    end
  end

  context "edit mode at 1400x1400" do
    setup do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"
      wait_for_stimulus "framework-explorer"
      assert_text ROLES.first
    end

    should "render every role and family name on one line" do
      assert_single_line_names
    end

    # The regression guard: a control back in the row's flow makes the name box
    # narrower than the row, and the names wrap again.
    should "float the row's controls over the name box instead of beside it" do
      tree = page.evaluate_script(TREE_PROBE_JS)

      (tree["roles"] + tree["families"]).each do |row|
        assert_equal "absolute", row["actionsPosition"],
                     "#{row['name']}'s controls are in the row's flow, so they reserve its width"
        assert_in_delta row["slotRight"], row["actionsRight"], 1,
                        "#{row['name']}'s controls do not sit over the right edge of its name box"
      end
    end

    # Floating them must not put them out of reach.
    should "keep the rename pencil, the solo pill and the kebab usable" do
      assert_selector "[data-tree-target='role'] button[aria-label='Edit role name']", visible: :all
      assert_selector "[data-tree-target='role'] button", text: "solo", visible: :all

      # Keyboard reveal: focusing a control inside the row shows the cluster,
      # which is the only way a keyboard user reaches any of it. The reveal is
      # a 150ms transition, so the computed opacity read in the same task is
      # still mid-flight — retry rather than measure once.
      page.execute_script(<<~JS)
        document.querySelector(
          "[data-tree-target='role'] button[aria-label='Edit role name']"
        ).focus();
      JS
      page.document.synchronize(Capybara.default_max_wait_time) do
        opacity = page.evaluate_script(<<~JS)
          getComputedStyle(document.querySelector(
            "[data-tree-target='role'] button[aria-label='Edit role name']"
          )).opacity
        JS
        unless opacity.to_f == 1.0
          raise Capybara::ExpectationNotMet,
                "the cluster stayed hidden (opacity #{opacity}) when a keyboard focused into the row"
        end
      end

      # And the pencil still finds its editor, which now lives in a Turbo Frame
      # it is no longer inside (`data-editor-host-frame`).
      page.execute_script(<<~JS)
        document.querySelector(
          "[data-tree-target='role'] button[aria-label='Edit role name']"
        ).click();
      JS
      assert_selector "[data-tree-target='role'] [data-editor-input]", visible: true
      press_escape

      page.execute_script(<<~JS)
        document.querySelector("[data-tree-target='role'] [aria-label='Role actions']").click();
      JS
      assert_selector "[role='menu']", visible: true, text: "Add level…"
    end
  end

  context "view mode at 1400x1400" do
    setup do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit framework_path(@framework_id)
      assert_text ROLES.first
    end

    # View mode has no pencil and no kebab, but it does have the solo pill —
    # which reserved 44 px of the same box.
    should "render every role and family name on one line" do
      assert_single_line_names
    end
  end

  context "the slide-over at 375x812" do
    setup do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      sign_in_as(@admin_user)
      visit edit_framework_path(@framework_id)
      assert_text "Edit mode"
      toggle_role_pane
    end

    should "render every role and family name on one line" do
      assert_single_line_names
    end
  end

  private

  def assert_single_line_names
    tree = page.evaluate_script(TREE_PROBE_JS)

    assert_equal FAMILIES.sort, tree["families"].map { |f| f["name"] }.sort
    assert_equal ROLES.sort, tree["roles"].map { |r| r["name"] }.sort

    (tree["roles"] + tree["families"]).each do |row|
      assert_equal 1, row["lines"],
                   "#{row['name']} wrapped onto #{row['lines']} lines in a " \
                   "#{row['slotWidth']}px box"
    end
  end
end
