# frozen_string_literal: true

require "test_helper"

class Components::Kit::BadgeTest < ActiveSupport::TestCase
  Badge = Components::Kit::Badge

  context "Components::Kit::Badge" do
    should "render the label in a span" do
      assert_match(%r{<span[^>]*>Pass</span>}, Badge.new("Pass").call)
    end

    should "default to a subtle neutral badge" do
      assert_equal Badge.classes(:subtle, tone: :neutral, size: :sm), Badge.classes
    end

    should "draw a legacy job-named variant as a subtle badge in its tone" do
      { default: :neutral, primary: :brand, info: :info, success: :success, warning: :warning }.each do |legacy, tone|
        assert_equal Badge.classes(:subtle, tone: tone), Badge.classes(legacy), "variant: :#{legacy}"
        assert_equal Badge.new("x", tone: tone).call, Badge.new("x", variant: legacy).call
      end
    end

    should "reject a tone it doesn't have" do
      assert_raises(KeyError) { Badge.new("x", tone: :primary).call }
    end

    should "put the icons either side of the label" do
      html = Badge.new("Draft", leading_icon: "pencil", trailing_icon: "chevron-down").call
      assert_match(/#icon-pencil.*Draft.*#icon-chevron-down/m, html)
    end

    should "mix extra attributes into its own" do
      html = Badge.new("3", id: "unread", class: "ml-2").call
      assert_includes html, 'id="unread"'
      assert_includes html, "#{Badge.classes} ml-2"
    end
  end
end
