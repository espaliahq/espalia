# frozen_string_literal: true

require "test_helper"

class Components::Kit::DropdownTest < ActiveSupport::TestCase
  def trigger_html(**options)
    Components::Kit::Dropdown.new.call do |dropdown|
      dropdown.trigger(**options) { "Menu" }
      dropdown.menu { } # rubocop:disable Lint/EmptyBlock
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
  end
end
