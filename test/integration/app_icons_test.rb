# frozen_string_literal: true

require "test_helper"

# Pins the favicon / app-icon surface: the `<head>` links, the web app
# manifest, and that every icon they reference is actually shipped under
# public/. A link to a missing file fails silently in the browser (a blank
# tab icon, a default home-screen tile), so the check has to live here.
# See docs/guidelines/app-icons.md.
class AppIconsTest < ActionDispatch::IntegrationTest
  context "the layout head" do
    setup { get new_user_session_path }

    should "link the icon set and the manifest" do
      assert_response :success
      assert_select "link[rel='icon'][href='/favicon.ico']"
      assert_select "link[rel='icon'][href='/icon.svg'][type='image/svg+xml']"
      assert_select "link[rel='apple-touch-icon'][href='/apple-touch-icon.png']"
      assert_select "link[rel='manifest'][href='/manifest.json']"
    end

    should "declare a theme colour per colour scheme" do
      assert_select "meta[name='theme-color'][media='(prefers-color-scheme: light)']"
      assert_select "meta[name='theme-color'][media='(prefers-color-scheme: dark)']"
      assert_select "meta[name='application-name'][content='GrowthOS']"
    end

    should "ship every file the head links to" do
      css_select("link[rel='icon'], link[rel='apple-touch-icon']").each do |link|
        assert_public_file link["href"]
      end
    end
  end

  context "GET /manifest.json" do
    setup { get pwa_manifest_path(format: :json) }

    should "describe the installable app" do
      assert_response :success
      manifest = JSON.parse(response.body)

      assert_equal "GrowthOS", manifest["name"]
      assert_equal "standalone", manifest["display"]
      assert_match(/\A#[0-9a-f]{6}\z/, manifest["theme_color"])
      assert_match(/\A#[0-9a-f]{6}\z/, manifest["background_color"])
    end

    should "reference icons that exist, including a maskable one" do
      icons = JSON.parse(response.body).fetch("icons")

      icons.each { |icon| assert_public_file icon["src"] }
      assert icons.any? { |icon| icon["purpose"] == "maskable" }, "no maskable icon"
      assert icons.any? { |icon| icon["sizes"] == "512x512" && icon["purpose"].nil? }, "no 512px any-purpose icon"
    end
  end

  context "the SVG mark" do
    should "carry an accessible name and description" do
      svg = Rails.root.join("public/icon.svg").read

      assert_includes svg, 'role="img"'
      assert_match(%r{<title id="[^"]+">GrowthOS</title>}, svg)
      assert_match(%r{<desc id="[^"]+">.+</desc>}, svg)
    end
  end

  private

  def assert_public_file(href)
    path = Rails.root.join("public", href.delete_prefix("/"))
    assert path.file?, "#{href} is linked but public/#{href.delete_prefix('/')} does not exist"
  end
end
