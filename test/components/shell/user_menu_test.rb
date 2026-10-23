# frozen_string_literal: true

require "test_helper"

class Components::Shell::UserMenuTest < ActiveSupport::TestCase
  def view_context
    ApplicationController.new
      .tap { |controller| controller.request = ActionDispatch::TestRequest.create }
      .view_context
  end

  context "the appearance control" do
    setup do
      @tenant = create(:tenant)
      user = build(:user, color_scheme: :light)
      @html = Nokogiri::HTML.fragment(view_context.render(Components::Shell::UserMenu.new(user: user, current_tenant: @tenant)))
    end

    should "offer Auto, Light and Dark as menu radios in a labelled group" do
      options = @html.css("[role='group'][aria-labelledby='color-scheme-label'] [role='menuitemradio']")
      assert_equal %w[Auto Light Dark], options.map(&:text)
      assert_equal "Appearance", @html.at_css("#color-scheme-label").text
    end

    should "check the person's stored choice" do
      checked = @html.css("[role='menuitemradio']").to_h { |option| [ option.text, option["aria-checked"] ] }
      assert_equal({ "Auto" => "false", "Light" => "true", "Dark" => "false" }, checked)
    end

    should "give the controller the endpoint and both browser chrome colours" do
      group = @html.at_css("[data-controller='color-scheme']")
      assert_equal "/settings/color_scheme", group["data-color-scheme-url-value"]
      assert_equal Tenant.browser_theme_color(@tenant, :light), group["data-color-scheme-light-color-value"]
      assert_equal Tenant.browser_theme_color(@tenant, :dark), group["data-color-scheme-dark-color-value"]
    end
  end
end
