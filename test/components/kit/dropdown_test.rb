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
    # Brand ink, not the brand: a teal ring on white is 2:1 (#447).
    should "draw a brand-ink focus ring by default" do
      html = trigger_html
      assert_includes html, "focus-visible:ring-2"
      assert_includes html, "focus-visible:ring-primary-ink"
    end

    should "take a caller's ring where the brand colour can't show" do
      html = trigger_html(focus_ring: "rounded-full focus-visible:ring-nav-fg")
      assert_includes html, "focus-visible:ring-2"
      assert_includes html, "focus-visible:ring-nav-fg"
      assert_not_includes html, "focus-visible:ring-primary-ink"
    end
  end
end
