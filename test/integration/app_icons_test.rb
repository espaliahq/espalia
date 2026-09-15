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

    should "link the icon set and the manifest, and ship every file it links" do
      assert_response :success
      assert_select "link[rel='icon'][href='/favicon.ico']"
      assert_select "link[rel='icon'][href='/icon.svg'][type='image/svg+xml']"
      assert_select "link[rel='apple-touch-icon'][href='/apple-touch-icon.png']"
      assert_select "link[rel='manifest'][href='/manifest.json']"

      css_select("link[rel='icon'], link[rel='apple-touch-icon'], link[rel='manifest']").each do |link|
        assert_public_file link["href"]
      end
    end

    should "declare the default theme colour per colour scheme when no tenant is active" do
      assert_select "meta[name='theme-color'][media='(prefers-color-scheme: light)']" \
                    "[content='#{Tenant::DEFAULT_NAV_BG_COLOR}']"
      assert_select "meta[name='theme-color'][media='(prefers-color-scheme: dark)']" \
                    "[content='#{Tenant::DEFAULT_NAV_BG_COLOR_DARK}']"
      assert_select "meta[name='application-name'][content='GrowthOS']"
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

    should "reference icons that exist, including a maskable one" do
      icons = JSON.parse(response.body).fetch("icons")

      icons.each { |icon| assert_public_file icon["src"] }
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
      # keeps it in step with Tenant::DEFAULT_NAV_BG_COLOR.
      assert_includes @svg, %(fill="#{Tenant::DEFAULT_NAV_BG_COLOR}")
    end
  end

  private

  def assert_public_file(href)
    path = Rails.root.join("public", href.delete_prefix("/"))
    assert path.file?, "#{href} is linked but public/#{href.delete_prefix('/')} does not exist"
  end
end
