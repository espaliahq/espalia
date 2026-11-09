# frozen_string_literal: true

require "application_system_test_case"

# Pins keep_page_focused (testing.md → "Focus Needs a Focused Page"): with the
# window minimized, the page must still take focus and run animation frames.
class FocusEmulationSystemTest < ApplicationSystemTestCase
  setup do
    tenant = FactoryBot.create(:tenant)
    user = FactoryBot.create(:user, password: TEST_PASSWORD)
    ActsAsTenant.with_tenant(tenant) { FactoryBot.create(:tenant_user, tenant: tenant, user: user) }
    sign_in_as(user)
  end

  should "keep a minimized window's page focused and painting" do
    visit root_path
    assert_text "Home"
    minimize_window

    state = page.evaluate_script(<<~JS)
      (() => {
        const button = document.querySelector("#user-menu button");
        button.focus();
        requestAnimationFrame(() => { document.documentElement.dataset.animationFrame = "ran" });
        return { hasFocus: document.hasFocus(), focus: button.matches(":focus"),
                 focusVisible: button.matches(":focus-visible") };
      })()
    JS

    assert state["hasFocus"], "the page lost focus with its window"
    assert state["focus"], "a script focus did not match :focus"
    assert state["focusVisible"], "a script focus did not match :focus-visible"
    assert_selector "html[data-animation-frame='ran']", visible: :all
  end

  private

  def minimize_window
    browser = page.driver.browser
    window = browser.execute_cdp("Browser.getWindowForTarget")["windowId"]
    browser.execute_cdp("Browser.setWindowBounds", windowId: window, bounds: { windowState: "minimized" })
  end
end
