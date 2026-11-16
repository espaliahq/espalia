# frozen_string_literal: true

require "test_helper"

class Components::Kit::DelegatedMenuTest < ActiveSupport::TestCase
  def render_menu
    html = Components::Kit::DelegatedMenu.new(kind: "position").call do |menu|
      menu.item(data: { action: "click->modal#open", edit_url: "{path}" }) { "Edit…" }
      menu.item(tone: :danger, data: { close_url: "{path}" }) { "Close…" }
    end
    Nokogiri::HTML5.fragment(html)
  end

  def render_trigger(**options)
    Nokogiri::HTML5.fragment(Components::Kit::DelegatedMenu::Trigger.new(label: "Actions for Designer", kind: "position", **options).call)
      .at_css("button")
  end

  context "Components::Kit::DelegatedMenu" do
    should "render its items once, in a template of its kind, with their placeholders" do
      template = render_menu.at_css("template[data-delegated-menu-kind=position]")
      items = template.css("button[role=menuitem]")

      assert_equal [ "Edit…", "Close…" ], items.map { it.text.strip }
      assert_equal "{path}", items.first["data-edit-url"]
      assert_includes items.last["class"], Components::Kit::Dropdown.item_classes(tone: :danger)
    end

    should "mount its controller with the window listeners it needs" do
      data = Components::Kit::DelegatedMenu.root_data(controller: "explorer-menu")

      assert_equal "explorer-menu", data[:controller]
      assert_includes data[:action], "keydown->explorer-menu#keydown"
      assert_includes data[:action], "click@window->explorer-menu#clickOutside"
    end
  end

  context "Components::Kit::DelegatedMenu::Trigger" do
    should "be a named menu button carrying its row's values" do
      trigger = render_trigger(values: { path: "/plans/1/positions/2", cost_centre: "Platform", level: nil })

      assert_equal "menu", trigger["aria-haspopup"]
      assert_equal "false", trigger["aria-expanded"]
      assert_equal "Actions for Designer", trigger["aria-label"]
      assert_equal "delegated-menu#toggle", trigger["data-action"]
      assert_equal "position", trigger["data-menu"]
      assert_equal "/plans/1/positions/2", trigger["data-menu-path"]
      assert_equal "Platform", trigger["data-menu-cost-centre"]
      assert_nil trigger["data-menu-level"]
      assert_equal "kit-menu-trigger", trigger["class"]
    end

    should "take another controller and its own chrome" do
      trigger = render_trigger(controller: "explorer-menu", class: "explorer-kebab", data: { cluster: "kebab" })

      assert_equal "explorer-menu#toggle", trigger["data-action"]
      assert_equal "explorer-kebab", trigger["class"]
      assert_equal "kebab", trigger["data-cluster"]
    end
  end
end
