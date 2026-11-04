# frozen_string_literal: true

require "test_helper"

class Components::Kit::AttentionDotTest < ActiveSupport::TestCase
  def render_dot(...)
    Nokogiri::HTML5.fragment(Components::Kit::AttentionDot.new(...).call)
  end

  context "Components::Kit::AttentionDot" do
    should "fill with the brand, edged in brand text, hidden from a screen reader that hears the label" do
      html = render_dot("needs your attention", class: "ml-1.5")
      dot = html.at_css("[data-mark]")

      assert_includes dot["class"].split, "bg-brand-strong"
      assert_includes dot["class"].split, "ring-current"
      assert_includes dot["class"].split, "ml-1.5"
      assert_equal "true", dot["aria-hidden"]
      assert_equal "(needs your attention)", html.at_css(".sr-only").text.strip
    end
  end
end
