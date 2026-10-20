# frozen_string_literal: true

require "test_helper"

class Components::Kit::SegmentedControlTest < ActiveSupport::TestCase
  SegmentedControl = Components::Kit::SegmentedControl

  def render_control(**options)
    html = SegmentedControl.new(**options).call do |control|
      control.segment("Highlight", data: { action: "feed#setMode" })
      control.segment("Filter", selected: true)
    end
    Nokogiri::HTML5.fragment(html).at_css("div")
  end

  context "Components::Kit::SegmentedControl" do
    should "be a named group of buttons that report aria-pressed" do
      control = render_control(label: "Focus mode")
      segments = control.css("button")

      assert_equal "group", control["role"]
      assert_equal "Focus mode", control["aria-label"]
      assert_equal %w[button button], segments.map { _1["type"] }
      assert_equal %w[false true], segments.map { _1["aria-pressed"] }
      assert_equal "feed#setMode", segments.first["data-action"]
    end

    should "make menuitemradio segments that report aria-checked inside a menu" do
      segments = render_control(item_role: :menuitemradio, aria: { labelledby: "scheme-label" }).css("button")

      assert_equal %w[menuitemradio menuitemradio], segments.map { _1["role"] }
      assert_equal %w[false true], segments.map { _1["aria-checked"] }
      assert segments.none? { _1.key?("aria-pressed") }
    end

    should "share the width between segments only when filled" do
      assert render_control(fill: true).css("button").all? { _1["class"].split.include?("flex-1") }
      assert render_control.css("button").none? { _1["class"].split.include?("flex-1") }
    end

    should "keep a caller's class on the track" do
      assert_includes render_control(class: "mt-1.5")["class"].split, "mt-1.5"
    end
  end
end
