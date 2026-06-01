# frozen_string_literal: true

require "test_helper"

class Components::Kit::BadgeTest < ActiveSupport::TestCase
  context "Components::Kit::Badge" do
    should "render the label" do
      html = Components::Kit::Badge.new("Pass", variant: :success).call
      assert_includes html, "Pass"
    end

    # Pin the AA-contrast text shades for tinted-fill variants: -700 on a -100
    # fill sits right at the 4.5:1 borderline, so success/warning use -800.
    should "use AA-contrast text on the success fill" do
      html = Components::Kit::Badge.new("Pass", variant: :success).call
      assert_includes html, "text-green-800"
      assert_not_includes html, "text-green-700"
    end

    should "use AA-contrast text on the warning fill" do
      html = Components::Kit::Badge.new("Overdue", variant: :warning).call
      assert_includes html, "text-amber-800"
      assert_not_includes html, "text-amber-700"
    end
  end
end
