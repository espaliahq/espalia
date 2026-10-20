# frozen_string_literal: true

require "test_helper"

# Pins the favicon / app-icon surface: the `<head>` links, the web app
# manifest, and that every icon they reference is actually shipped under
# public/. A link to a missing file fails silently in the browser (a blank
# tab icon, a default home-screen tile), so the check has to live here.
# See docs/guidelines/app-icons.md.
class AppIconsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  context "the layout head for a themed tenant" do
    setup do
      @tenant = create(:tenant, nav_bg_color: "#123456", nav_bg_color_dark: "#654321")
      user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: user, role: :member) }
      sign_in user
      get root_path
    end

    should "paint the browser chrome in the tenant's navbar colours" do
      assert_response :success
      assert_select "meta[name='theme-color'][media='(prefers-color-scheme: light)'][content='#123456']"
      assert_select "meta[name='theme-color'][media='(prefers-color-scheme: dark)'][content='#654321']"
    end
  end

  context "the layout head" do
    setup { get new_user_session_path }

    should "link the icon set and the manifest, versioned, and ship every file it links" do
      assert_response :success
      v = AppIconsHelper.version
      assert_match(/\A\h{8}\z/, v)
      assert_select "link[rel='icon'][href='/favicon.ico?v=#{v}']"
      assert_select "link[rel='icon'][href='/icon.svg?v=#{v}'][type='image/svg+xml']"
      assert_select "link[rel='apple-touch-icon'][href='/apple-touch-icon.png?v=#{v}']"
      assert_select "link[rel='manifest'][href='/manifest.json?v=#{v}']"

      css_select("link[rel='icon'], link[rel='apple-touch-icon'], link[rel='manifest']").each do |link|
        assert_public_file link["href"]
      end
    end

    should "replace the theme colour with the sign-in page's own" do
      assert_select "meta[name='theme-color']", count: 1
      assert_select "meta[name='theme-color'][content='#{Views::Users::Sessions::NewView::BROWSER_THEME_COLOR}']"
      assert_select "meta[name='application-name'][content='GrowthOS']"
    end
  end

  context "the layout head on a page without its own theme colour" do
    setup { get new_user_password_path }

    should "declare the default theme colour per colour scheme when no tenant is active" do
      assert_response :success
      assert_select "meta[name='theme-color'][media='(prefers-color-scheme: light)']" \
                    "[content='#{Tenant::DEFAULT_NAV_BG_COLOR}']"
      assert_select "meta[name='theme-color'][media='(prefers-color-scheme: dark)']" \
                    "[content='#{Tenant::DEFAULT_NAV_BG_COLOR_DARK}']"
    end
  end

  context "the sign-in page's brand mark" do
    should "draw the same paths as bin/build-icons" do
      script = Rails.root.join("bin/build-icons").read
      source = %w[STEPS LEAF].map { |name| script[/^const #{name} = "([^"]+)";$/, 1] }

      assert_equal source, Views::Users::Sessions::NewView::MARK_PATHS
    end
  end

  context "GET /manifest.json" do
    setup { get "/manifest.json" }

    should "describe the installable app in the brand colour" do
      assert_response :success
      manifest = JSON.parse(response.body)

      assert_equal "GrowthOS", manifest["name"]
      assert_equal "standalone", manifest["display"]
      assert_equal Tenant::DEFAULT_NAV_BG_COLOR, manifest["theme_color"]
      assert_match Tenant::HEX_COLOR_FORMAT, manifest["background_color"]
    end

    should "reference PNG icons that exist at the sizes it claims, including a maskable one" do
      icons = JSON.parse(response.body).fetch("icons")

      icons.each do |icon|
        assert_equal "image/png", icon["type"], "#{icon['src']}: manifest icons must be PNG (Chromium can't decode SVG here)"
        assert_public_file icon["src"]
        assert_equal icon["sizes"], png_dimensions(icon["src"]), "#{icon['src']} is not the size the manifest claims"
      end
      assert icons.any? { |icon| icon["purpose"] == "maskable" }, "no maskable icon"
      assert icons.any? { |icon| icon["sizes"] == "512x512" && icon["purpose"].nil? }, "no 512px any-purpose icon"
    end
  end

  context "the SVG mark" do
    setup { @svg = Rails.root.join("public/icon.svg").read }

    should "carry an accessible name and description" do
      assert_includes @svg, 'role="img"'
      assert_match(%r{<title id="[^"]+">GrowthOS</title>}, @svg)
      assert_match(%r{<desc id="[^"]+">.+</desc>}, @svg)
    end

    should "be painted in the same teal the navbar and manifest use" do
      # COLOR in bin/build-icons is a literal (it's a node script) — this is what
      # keeps it in step with Tenant::DEFAULT_NAV_BG_COLOR, and the CSS tokens
      # are literals too, so pin those to the same constant here.
      assert_includes @svg, %(fill="#{Tenant::DEFAULT_NAV_BG_COLOR}")

      css = Rails.root.join("app/assets/tailwind/application.css").read
      assert_includes css, "--color-nav-bg: #{Tenant::DEFAULT_NAV_BG_COLOR};"
      assert_includes css, "--color-nav-bg: #{Tenant::DEFAULT_NAV_BG_COLOR_DARK};"
    end
  end

  private

  # "WxH" from a PNG's IHDR chunk — enough to catch a raster that was not
  # regenerated at the size the manifest advertises.
  def png_dimensions(href)
    header = Rails.root.join("public", href.delete_prefix("/")).binread(24)
    header.unpack("@16N2").join("x")
  end

  def assert_public_file(href)
    path = Rails.root.join("public", href.delete_prefix("/").sub(/\?.*\z/, ""))
    assert path.file?, "#{href} is linked but public/#{href.delete_prefix('/')} does not exist"
  end
end
