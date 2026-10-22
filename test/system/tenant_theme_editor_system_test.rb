# frozen_string_literal: true

require "application_system_test_case"

# The Theme page: choosing a preset or Custom, the live preview, Save and Cancel.
class TenantThemeEditorSystemTest < ApplicationSystemTestCase
  BRAND_LIGHT = "tenant[custom_theme][brand][light]"
  NAV_LIGHT = "tenant[custom_theme][nav-surface][light]"
  NAV_DARK = "tenant[custom_theme][nav-surface][dark]"
  CUSTOM_FIELDSET = "fieldset[data-theme-live-preview-target='custom']"
  # What the live preview renders once each choice lands, and only then.
  CHOICE_RENDERED = {
    "default" => "html:not([data-theme]) #{CUSTOM_FIELDSET}[hidden]",
    "bento" => "html[data-theme='bento']",
    "custom" => "html:not([data-theme]) #{CUSTOM_FIELDSET}:not([hidden])"
  }.freeze

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
    end

    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    emulate_scheme "light"
    sign_in_as(@admin_user)
  end

  teardown { emulate_scheme "light" }

  should "preview each preset live, then save Bento" do
    open_editor
    assert_nil html_theme
    assert_no_selector CUSTOM_FIELDSET, visible: true

    choose_theme "bento"
    assert_equal "bento", html_theme
    assert_equal "#c6f226", root_variable("--gos-brand")

    choose_theme "default"
    assert_nil html_theme
    assert_equal "#32c8c8", root_variable("--gos-brand")

    choose_theme "bento"
    click_button_with_js_fallback "Save", expect_text: "Theme saved."

    assert_equal "bento", @tenant.reload.theme
    visit tenant_root_path
    assert_equal "bento", html_theme
    assert_equal "rgb(198, 242, 38)", computed("nav", "backgroundColor")
  end

  should "customise brand and nav, show the helper's text, save and keep them on reload" do
    open_editor
    choose_theme "custom"
    assert_selector CUSTOM_FIELDSET, visible: true

    set_color_field(BRAND_LIGHT, "#7c3aed")
    set_color_field(NAV_LIGHT, "#f5e663")
    set_color_field(NAV_DARK, "#2a0f3d")

    assert_equal "#7c3aed", page.evaluate_script("document.documentElement.style.getPropertyValue('--tenant-brand')")
    assert_equal "rgb(245, 230, 99)", computed("nav", "backgroundColor")
    assert_equal "rgb(245, 230, 99)", frame_nav_background("light")
    assert_text "#f5e663 · text black"

    click_button_with_js_fallback "Save", expect_text: "Theme saved."
    @tenant.reload
    assert_equal "custom", @tenant.theme
    assert_equal "#7c3aed", @tenant.custom_role("brand", :light)
    assert_equal "#f5e663", @tenant.custom_role("nav-surface", :light)

    visit tenant_root_path
    assert_nil html_theme
    assert_equal "rgb(245, 230, 99)", computed("nav", "backgroundColor")
    assert_equal "rgb(0, 0, 0)", computed("nav", "color")

    emulate_scheme "dark"
    assert_equal "rgb(42, 15, 61)", computed("nav", "backgroundColor")
    assert_equal "rgb(255, 255, 255)", computed("nav", "color")
  end

  should "fill buttons with the brand itself and name the text the helper picks for it" do
    open_editor
    choose_theme "custom"

    set_color_field(BRAND_LIGHT, "#facc15")
    within("#theme-brand-light-readout") { assert_text "#facc15 · button text black" }
    assert_equal [ 250, 204, 21 ], rgb(frame_button_background("light"))

    set_color_field(BRAND_LIGHT, "#1e3a8a")
    within("#theme-brand-light-readout") { assert_text "#1e3a8a · button text white" }
  end

  should "drop a stored value from Custom's frames when its field is cleared" do
    @tenant.update!(theme: "custom", font_family: "Roboto")
    open_editor
    assert_includes frame_style("light", "body", "fontFamily"), "Roboto"

    js_fill_in "Font", with: ""

    assert_not_includes frame_style("light", "body", "fontFamily"), "Roboto"
    assert_not_includes frame_style("dark", "body", "fontFamily"), "Roboto"
  end

  should "put the saved choice and values back on Cancel" do
    @tenant.update!(theme: "custom", custom_theme: { "brand" => { "light" => "#abcdef" } })
    open_editor

    set_color_field(BRAND_LIGHT, "#ff8800")
    choose_theme "bento"
    assert_equal "bento", html_theme

    assert_equal true, dispatch_js_click("[data-action~='theme-live-preview#revert']")

    assert_nil html_theme
    assert_selector "input[type=radio][value=custom]:checked"
    assert_equal "#abcdef", find("input[name='#{BRAND_LIGHT}']", visible: :all).value
    assert_equal "#abcdef", page.evaluate_script("document.documentElement.style.getPropertyValue('--tenant-brand')")
  end

  should "reach every choice and Custom's controls from the keyboard" do
    open_editor
    find("input[type=radio][value=default]").send_keys(:right)
    assert_selector "input[type=radio][value=bento]:checked"
    assert_equal "bento", html_theme

    find("input[type=radio][value=bento]").send_keys(:right)
    assert_selector "input[type=radio][value=custom]:checked"

    reachable = page.evaluate_script(<<~JS)
      [...document.querySelectorAll("[data-theme-live-preview-target='field']")]
        .filter((el) => el.tabIndex >= 0 && !el.matches(":disabled") && el.checkVisibility())
        .map((el) => el.getAttribute("aria-label") || el.labels[0]?.textContent)
    JS
    assert_equal [ "Brand, light", "Brand, dark", "Navbar, light", "Navbar, dark", "Font" ], reachable
    assert_selector "iframe[tabindex='-1'][aria-hidden='true']", count: 6, visible: :all
  end

  private

  def emulate_scheme(scheme)
    page.driver.browser.execute_cdp(
      "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: scheme } ]
    )
  end

  def open_editor
    visit tenant_theme_path
    wait_for_stimulus "theme-live-preview"
  end

  # A bare `choose` drops its click on a starved runner, so dispatch it and wait for the preview to follow.
  def choose_theme(value)
    rendered = CHOICE_RENDERED.fetch(value)
    raise ArgumentError, "#{value} is already the previewed choice" if page.has_css?(rendered, visible: :all, wait: 0)

    assert_equal true, dispatch_js_click("input[type=radio][name='tenant[theme]'][value='#{value}']")
    assert_selector rendered, visible: :all
  end

  def html_theme
    page.evaluate_script("document.documentElement.dataset.theme ?? null")
  end

  def root_variable(name)
    page.evaluate_script("getComputedStyle(document.documentElement).getPropertyValue('#{name}').trim()")
  end

  def computed(selector, property)
    page.evaluate_script("getComputedStyle(document.querySelector('#{selector}')).#{property}")
  end

  # Any CSS colour (rgb, oklab, color(…)) as the [r, g, b] the screen shows.
  def rgb(color)
    page.evaluate_script(<<~JS)
      (() => {
        const pixel = document.createElement("canvas").getContext("2d");
        pixel.fillStyle = "#{color}";
        pixel.fillRect(0, 0, 1, 1);
        return [...pixel.getImageData(0, 0, 1, 1).data.slice(0, 3)];
      })()
    JS
  end

  def frame_nav_background(scheme)
    frame_style(scheme, "nav", "backgroundColor")
  end

  def frame_button_background(scheme)
    frame_style(scheme, "[data-theme-preview-button]", "backgroundColor")
  end

  # An element in Custom's preview frame for a scheme, once it has loaded and been painted.
  def frame_style(scheme, selector, property)
    script = <<~JS
      (() => {
        const frame = document.querySelector('iframe[data-theme="custom"][data-scheme="#{scheme}"]');
        const el = frame?.contentDocument?.querySelector('#{selector}');
        el?.getAnimations().forEach((animation) => animation.finish());
        return el ? frame.contentWindow.getComputedStyle(el).#{property} : null;
      })()
    JS
    Timeout.timeout(Capybara.default_max_wait_time) do
      loop do
        value = page.evaluate_script(script)
        return value if value
        sleep 0.1
      end
    end
  end

  # Colour inputs don't take `fill_in`; setting the value and dispatching `input` is what a picker does.
  def set_color_field(name, hex)
    page.execute_script(<<~JS)
      const el = document.querySelector('input[name="#{name}"]');
      el.value = "#{hex}";
      el.dispatchEvent(new Event("input", { bubbles: true }));
    JS
  end
end
