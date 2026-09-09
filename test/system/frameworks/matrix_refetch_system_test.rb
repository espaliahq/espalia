# frozen_string_literal: true

require "application_system_test_case"

# Pins the matrix's re-fetch hygiene (#383): a burst of filter changes costs
# ONE matrix fetch, and the wait is visible from the first click rather than
# only once Turbo has a request in flight.
#
# Both halves are measured from the browser itself — resource timings for the
# fetches, a MutationObserver for the indicator — not from what the DOM happens
# to show afterwards. A debounce that silently dropped the last toggle would
# still leave a "correct"-looking grid from an earlier fetch, and a busy bar
# that never appeared would satisfy any "it is hidden now" assertion.
class Frameworks::MatrixRefetchSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  # Roles the burst toggles off, one click each.
  BURST_SIZE = 5

  # Gap between the burst's clicks. Comfortably longer than Turbo's own
  # same-task coalescing and comfortably shorter than the controller's 300ms
  # debounce, so the burst is genuinely N interactions arriving as one fetch.
  BURST_GAP_MS = 30

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Refetch Framework")

      family_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, family_id, "Software Engineering", department: "Engineering")

      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")

      # One role per burst click, each holding the only level at its ordinal, so
      # unchecking any one of them provably changes the rendered column set —
      # the fetch has to be worth making for "one fetch" to mean anything.
      @role_ids = Array.new(BURST_SIZE) do |i|
        role_id = SecureRandom.uuid_v7
        handler.add_role(@framework_id, role_id, family_id, "Engineer #{i + 1}", "E#{i + 1}", "ic")
        handler.add_level(@framework_id, SecureRandom.uuid_v7, role_id, i + 1,
                          "Engineer level #{i + 1}", "L#{i + 1}", is_entry: i.zero?)
        handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, role_id)
        handler.set_behavioural_expectation(
          @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, cap_id, i + 1,
          expectation_text(i + 1)
        )
        role_id
      end

      handler.publish_version(@framework_id, "test")
    end

    sign_in_as(@user)
  end

  context "a burst of role toggles" do
    should "cost one matrix fetch, not one per click" do
      open_explorer

      # Every role but the last goes; the last one's column proves the burst's
      # final state is what rendered, not an intermediate one.
      toggle_roles_off(@role_ids.first(BURST_SIZE - 1))

      assert_no_text expectation_text(1)
      assert_text expectation_text(BURST_SIZE)
      assert_matrix_fetch_count 1
    end

    should "push the browser URL immediately, ahead of the debounced fetch" do
      open_explorer

      toggle_roles_off([ @role_ids.first ])

      # Read synchronously, inside the debounce window: the address bar (and the
      # axis read-back the next filter change depends on) must never lag the
      # controls, however long the fetch is deferred.
      remaining = page.evaluate_script("new URL(window.location).searchParams.getAll('roles[]')")
      assert_equal @role_ids.drop(1).sort, remaining.sort
      assert_equal 0, matrix_fetch_count, "the fetch should still be pending"

      assert_no_text expectation_text(1)
      assert_matrix_fetch_count 1
    end
  end

  context "the busy indicator" do
    should "cover the whole wait — the debounce window included" do
      open_explorer
      assert_no_selector "[data-matrix-target='busy']", visible: true
      watch_busy_bar

      toggle_roles_off([ @role_ids.first ])

      # Recorded by the observer rather than polled for: the bar's lifetime is
      # ~300ms of debounce plus one fetch, which a poll can miss entirely.
      assert page.evaluate_script("window.__busyShown"),
             "the busy bar never appeared during the filter change"

      assert_no_text expectation_text(1)
      assert_no_selector "[data-matrix-target='busy']", visible: true
    end

    should "announce the wait to assistive technology" do
      open_explorer

      # The bar is a 2px stripe — it conveys nothing without a text alternative.
      bar = find("[data-matrix-target='busy']", visible: :all)
      assert_equal "status", bar[:role]
      assert_equal "polite", bar["aria-live"]
      assert_equal "Updating the matrix…", bar.text(:all).strip
    end
  end

  context "on mobile" do
    should "still coalesce a burst into one fetch" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      open_explorer

      toggle_roles_off(@role_ids.first(BURST_SIZE - 1))

      assert_no_text expectation_text(1)
      assert_matrix_fetch_count 1
    end
  end

  private

  def expectation_text(ordinal)
    "Weighs options and explains reasoning at level #{ordinal}"
  end

  def open_explorer
    visit framework_path(@framework_id)
    wait_for_stimulus "matrix"
    assert_text expectation_text(1)
    page.execute_script("performance.clearResourceTimings()")
  end

  # Clicks each role checkbox in its own task, `BURST_GAP_MS` apart — the way a
  # fast user's clicks land, and unlike a single synchronous loop, which Turbo
  # coalesces on its own (so a loop would pass with no debounce at all). The
  # whole burst still fits inside one debounce window.
  def toggle_roles_off(role_ids)
    page.execute_script(<<~JS, role_ids, BURST_GAP_MS)
      const [ ids, gap ] = [ arguments[0], arguments[1] ]
      ids.forEach((id, i) => setTimeout(() => {
        const cb = document.querySelector(`input[data-role-id="${id}"]`)
        if (!cb) throw new Error(`no role checkbox for ${id}`)
        cb.checked = false
        cb.dispatchEvent(new Event("change", { bubbles: true }))
      }, i * gap))
    JS
    # Let the whole burst land before the caller reads anything back.
    sleep((role_ids.size * BURST_GAP_MS) / 1000.0)
  end

  def watch_busy_bar
    page.execute_script(<<~JS)
      window.__busyShown = false
      const bar = document.querySelector("[data-matrix-target='busy']")
      if (!bar) throw new Error("no busy bar in the DOM")
      if (!bar.hidden) window.__busyShown = true
      new MutationObserver(() => { if (!bar.hidden) window.__busyShown = true })
        .observe(bar, { attributes: true, attributeFilter: [ "hidden" ] })
    JS
  end

  def matrix_fetch_count
    page.evaluate_script(<<~JS)
      performance.getEntriesByType("resource")
        .filter((e) => e.name.includes("/matrix")).length
    JS
  end

  def assert_matrix_fetch_count(expected)
    actual = matrix_fetch_count
    assert_equal expected, actual,
                 "expected #{expected} matrix fetch(es) for the burst, got #{actual}"
  end
end
