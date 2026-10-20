# frozen_string_literal: true

require "test_helper"

class Components::Kit::DropdownTest < ActiveSupport::TestCase
  def trigger_html(role: "menu", **options)
    Components::Kit::Dropdown.new(role: role).call do |dropdown|
      dropdown.trigger(**options) { "Menu" }
      dropdown.menu { } # rubocop:disable Lint/EmptyBlock
    end
  end

  def trigger(html) = Nokogiri::HTML5.fragment(html).at_css("[data-dropdown-target='trigger']")

  def items_html
    Components::Kit::Dropdown.new.call do |dropdown|
      dropdown.trigger { "Menu" }
      dropdown.menu do
        dropdown.item(href: "/settings") { "Settings" }
        dropdown.item(tone: :danger, size: :xs, data: { action: "x#delete" }) { "Delete" }
      end
    end
  end

  # The trigger removes the browser outline, so it must draw its own
  # indicator or keyboard focus disappears (#322, WCAG 2.4.7).
  context "Components::Kit::Dropdown#trigger" do
    should "draw the focus role's ring by default" do
      html = trigger_html
      assert_includes html, "focus-visible:ring-2"
      assert_includes html, "focus-visible:ring-focus"
    end

    should "take a caller's ring shape" do
      html = trigger_html(focus_ring: "rounded-full focus-visible:ring-focus")
      assert_includes html, "focus-visible:ring-2"
      assert_includes html, "rounded-full focus-visible:ring-focus"
    end

    should "announce a menu, or the panel's own role" do
      assert_equal "menu", trigger(trigger_html)["aria-haspopup"]

      dialog = Nokogiri::HTML5.fragment(trigger_html(role: "dialog"))
      assert_equal "dialog", dialog.at_css("button")["aria-haspopup"]
      assert_equal "dialog", dialog.at_css("[data-dropdown-target='menu']")["role"]
    end

    should "render a Kit::Button that drives the menu" do
      button = trigger(trigger_html(label: "Comment actions", button: { variant: :ghost, size: :xs, icon: true }))

      assert_equal "button", button.name
      assert_equal "dropdown#toggle", button["data-action"]
      assert_equal "Comment actions", button["aria-label"]
      assert_equal "false", button["aria-expanded"]
      assert_includes button["class"], "bg-transparent", "the Button's own ghost classes"
      assert_not_includes button["class"], "focus-visible:ring-2", "the Button owns its focus ring"
    end
  end

  context "Components::Kit::Dropdown#trigger_attributes" do
    should "carry what a site's own trigger needs" do
      attrs = Components::Kit::Dropdown.new.trigger_attributes

      assert_equal({ haspopup: "menu", expanded: "false" }, attrs[:aria])
      assert_equal({ action: "dropdown#toggle", dropdown_target: "trigger" }, attrs[:data])
    end
  end

  context "Components::Kit::Dropdown#item" do
    should "render a link with href and a button without" do
      items = Nokogiri::HTML5.fragment(items_html).css("[role='menuitem']")

      assert_equal %w[a button], items.map(&:name)
      assert_equal "/settings", items[0]["href"]
      assert_equal "button", items[1]["type"]
      assert_equal "x#delete", items[1]["data-action"]
    end

    should "highlight with the neutral fill, and danger with its own" do
      assert_includes Components::Kit::Dropdown.item_classes, "hover:bg-default-hover"
      assert_includes Components::Kit::Dropdown.item_classes(tone: :danger), "text-danger hover:bg-danger-subtle"
      assert_not_includes Components::Kit::Dropdown.item_classes, "brand"
    end
  end
end
