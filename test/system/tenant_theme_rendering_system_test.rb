# frozen_string_literal: true

require "application_system_test_case"

# What a tenant's theme looks like in the browser: which value of each role
# applies in each scheme, and the text the contrast helper picks for the nav.
class TenantThemeRenderingSystemTest < ApplicationSystemTestCase
  context "a Custom theme as rendered" do
    setup do
      @custom = FactoryBot.create(:tenant, name: "Lime Co", theme: "custom", custom_theme: {
        "brand" => { "light" => "#6366f1", "dark" => "#818cf8" },
        "nav-surface" => { "light" => "#dbfc45" }
      })
      user = FactoryBot.create(:user, password: "password123")
      ActsAsTenant.with_tenant(@custom) { FactoryBot.create(:tenant_user, tenant: @custom, user: user) }
      sign_in_as(user)
      visit root_path
      assert_selector "nav"
    end

    should "use the light values, and the dark ones once the page is dark" do
      set_scheme("light")
      assert_equal [ 99, 102, 241 ], rendered_rgb("--gos-brand")
      assert_equal [ 219, 252, 69 ], rendered_rgb("--gos-nav-surface")

      set_scheme("dark")
      assert_equal [ 129, 140, 248 ], rendered_rgb("--gos-brand")
    end

    should "fall back to Default's dark value for a role with no dark value" do
      set_scheme("dark")
      assert_equal [ 50, 200, 200 ], rendered_rgb("--gos-nav-surface")
    end

    should "pick nav text from the contrast helper: black on lime, and on Default's dark teal" do
      set_scheme("light")
      assert_equal [ 0, 0, 0 ], rendered_rgb("--gos-nav-content")

      set_scheme("dark")
      assert_equal [ 0, 0, 0 ], rendered_rgb("--gos-nav-content")
    end
  end

  context "a preset" do
    should "name the preset on <html>, load its font, and inject none of the tenant's own" do
      preset = FactoryBot.create(:tenant, name: "Bento Co", theme: "bento", font_family: "Poppins",
                                          custom_theme: { "brand" => { "light" => "#6366f1" } })
      user = FactoryBot.create(:user, password: "password123")
      ActsAsTenant.with_tenant(preset) { FactoryBot.create(:tenant_user, tenant: preset, user: user) }
      sign_in_as(user)
      visit root_path

      assert_selector "html[data-theme='bento']"
      assert_no_selector "style#tenant-theme", visible: :all
      assert_selector "link[rel='stylesheet'][href*='family=Plus+Jakarta+Sans']", visible: :all
      assert_no_selector "link[href*='family=Poppins']", visible: :all
    end
  end

  context "the root" do
    should "paint the page surface, so a scroll bouncing past the page shows it in either scheme" do
      user = FactoryBot.create(:user, password: "password123")
      tenant = FactoryBot.create(:tenant)
      ActsAsTenant.with_tenant(tenant) { FactoryBot.create(:tenant_user, tenant: tenant, user: user) }
      sign_in_as(user)

      { "desktop" => DESKTOP_SIZE, "phone" => MOBILE_SIZE }.each do |width, size|
        page.driver.browser.manage.window.resize_to(*size)
        visit root_path
        assert_selector "body > .bg-page"

        %w[light dark].each do |scheme|
          set_scheme(scheme)
          root, page_surface = evaluate_script(<<~JS)
            [ document.documentElement, document.querySelector("body > .bg-page") ]
              .map((el) => getComputedStyle(el).backgroundColor)
          JS
          assert_equal page_surface, root, "the root should match the page in #{scheme} on a #{width}"
        end
      end
    end
  end

  private

  def set_scheme(scheme)
    page.execute_script("document.documentElement.dataset.scheme = #{scheme.to_json}")
  end

  # The variable's colour as the browser paints it, read back from a canvas so
  # every colour syntax (hex, color(), contrast-color()) compares as sRGB bytes.
  def rendered_rgb(variable)
    evaluate_script(<<~JS)
      (() => {
        const probe = document.createElement("div");
        probe.style.color = "var(#{variable})";
        document.body.appendChild(probe);
        const color = getComputedStyle(probe).color;
        probe.remove();
        const ctx = document.createElement("canvas").getContext("2d");
        ctx.fillStyle = color;
        ctx.fillRect(0, 0, 1, 1);
        return Array.from(ctx.getImageData(0, 0, 1, 1).data.slice(0, 3));
      })()
    JS
  end
end
