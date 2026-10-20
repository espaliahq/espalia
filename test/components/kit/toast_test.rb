# frozen_string_literal: true

require "test_helper"

class Components::Kit::ToastTest < ActiveSupport::TestCase
  def render_toast(**options)
    html = Components::Kit::Toast.new(**options).call { "Assessment cycle defined." }
    Nokogiri::HTML5.fragment(html).at_css("div")
  end

  context "Components::Kit::Toast" do
    should "wire the flash controller to dismiss itself after five seconds" do
      toast = render_toast(tone: :success)

      assert_equal "flash", toast["data-controller"]
      assert_equal "5000", toast["data-flash-delay-value"]
      assert_equal "flash#dismiss", toast.at_css("button[aria-label='Dismiss']")["data-action"]
    end

    should "stay longer for danger, and as long as asked" do
      assert_equal "7000", render_toast(tone: :danger)["data-flash-delay-value"]
      assert_equal "0", render_toast(dismiss_after: 0)["data-flash-delay-value"]
    end

    should "be an alert with the tone's colours and a shadow" do
      classes = render_toast(tone: :danger)["class"].split

      assert_equal "alert", render_toast(tone: :danger)["role"]
      assert_includes classes, "tone-danger"
      assert_includes classes, "shadow-lg"
    end
  end

  context "Components::Kit::Toast::Stack" do
    should "float below the navbar and let clicks through its gaps" do
      stack = Nokogiri::HTML5.fragment(Components::Kit::Toast::Stack.new.call).at_css("div")
      classes = stack["class"].split

      assert_includes classes, "fixed"
      assert_includes classes, "top-16"
      assert_includes classes, "pointer-events-none"
    end
  end
end
