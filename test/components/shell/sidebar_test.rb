# frozen_string_literal: true

require "test_helper"

class Components::Shell::SidebarTest < ActiveSupport::TestCase
  setup do
    @drawer = Nokogiri::HTML.fragment(
      Components::Shell::Sidebar.new(links: [ { label: "Home", href: "/" } ]).call
    ).at_css("aside")
  end

  context "Components::Shell::Sidebar" do
    should "be the drawer the navbar toggle controls" do
      assert_equal Components::Shell::Sidebar::DRAWER_ID, @drawer["id"]
      assert_equal "drawer", @drawer["data-sidebar-target"]
    end

    should "close on Escape and when focus leaves it" do
      assert_includes @drawer["data-action"], "keydown.esc@window->sidebar#escape"
      assert_includes @drawer["data-action"], "focusout->sidebar#focusOut"
    end

    should "carry a labelled close button" do
      close = @drawer.at_css("button[aria-label='Close menu']")

      assert_equal "sidebar#dismiss", close["data-action"]
      assert_equal "button", close["type"]
    end
  end
end
