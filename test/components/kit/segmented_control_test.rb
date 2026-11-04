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

    should "mark a segment with a dot and say why only to a screen reader" do
      html = SegmentedControl.new(label: "Group").call do |control|
        control.segment("By report")
        control.segment("By person", marked: "needs your attention")
      end
      plain, marked = Nokogiri::HTML5.fragment(html).css("button")

      assert_nil plain.at_css("[data-mark]")
      assert_equal "true", marked.at_css("[data-mark]")["aria-hidden"]
      assert_equal "By person (needs your attention)", marked.text
    end

    should "swap in the short label below the sm breakpoint" do
      html = SegmentedControl.new(label: "Scope").call do |control|
        control.segment("My whole org", short: "Whole org")
      end
      segment = Nokogiri::HTML5.fragment(html).at_css("button")

      assert_equal "Whole org", segment.at_css("span.sm\\:hidden").text
      assert_equal "My whole org", segment.at_css("span.max-sm\\:hidden").text
    end

    should "share the width between segments only when filled" do
      assert render_control(fill: true).css("button").all? { _1["class"].split.include?("flex-1") }
      assert render_control.css("button").none? { _1["class"].split.include?("flex-1") }
    end

    should "make link segments that mark the selected one as the current page" do
      html = SegmentedControl.new(label: "Scope").call do |control|
        control.segment("Whole cycle", href: "/cycles/1/cohort", selected: true)
        control.segment("My org", href: "/cycles/1/cohort?scope=mine")
      end
      links = Nokogiri::HTML5.fragment(html).css("a")

      assert_equal [ "page", nil ], links.map { _1["aria-current"] }
      assert links.none? { _1.key?("aria-pressed") || _1.key?("type") }
    end

    should "reach 44px for a touch target" do
      assert render_control(touch: true).css("button").all? { _1["class"].split.include?("min-h-11") }
    end

    should "keep a caller's class on the track" do
      assert_includes render_control(class: "mt-1.5")["class"].split, "mt-1.5"
    end
  end
end
