# frozen_string_literal: true

require "test_helper"

class Components::Kit::AlertTest < ActiveSupport::TestCase
  def render_alert(**options, &block)
    block ||= proc { "Weight must be between 0 and 10." }
    Nokogiri::HTML5.fragment(Components::Kit::Alert.new(**options).call(&block)).at_css("div")
  end

  context "Components::Kit::Alert" do
    should "colour itself only through the tone, for every tone" do
      Components::Kit::Alert::TONES.each do |tone, tone_class|
        classes = render_alert(tone: tone)["class"].split

        assert_includes classes, tone_class
        assert_empty classes.grep(/\A(?:dark:)?(?:bg|text|border)-(?:red|green|amber|blue|gray)-/), "#{tone} uses a palette step"
      end
    end

    should "swap to the tone's strong fill when solid" do
      classes = render_alert(tone: :warning, emphasis: :solid)["class"].split

      assert_includes classes, "bg-tone-strong"
      assert_includes classes, "text-tone-content-inverse"
      assert_not_includes classes, "bg-tone-subtle"
    end

    should "announce politely by default and assertively for danger" do
      assert_equal "status", render_alert["role"]
      assert_equal "alert", render_alert(tone: :danger)["role"]
      assert_equal "status", render_alert(tone: :danger, role: :status)["role"]
    end

    should "render the title above the body" do
      alert = render_alert(title: "The last publish attempt failed")

      assert_equal "The last publish attempt failed", alert.at_css("p.font-semibold").text
      assert_includes alert.text, "Weight must be between 0 and 10."
    end

    should "have no dismiss button or flash controller unless asked" do
      alert = render_alert

      assert_nil alert.at_css("button")
      assert_nil alert["data-controller"]
    end

    should "dismiss through the flash controller without a timer" do
      alert = render_alert(dismissible: true)
      button = alert.at_css("button")

      assert_equal "flash", alert["data-controller"]
      assert_equal "0", alert["data-flash-delay-value"]
      assert_equal "Dismiss", button["aria-label"]
      assert_equal "flash#dismiss", button["data-action"]
      assert_includes button["class"].split, "size-11"
    end

    should "remove itself after dismiss_after milliseconds" do
      alert = render_alert(dismiss_after: 8000)

      assert_equal "flash", alert["data-controller"]
      assert_equal "8000", alert["data-flash-delay-value"]
      assert_nil alert.at_css("button")
    end

    should "render the action slot after the body" do
      html = Components::Kit::Alert.new(tone: :warning).call do |alert|
        alert.action { "Place them" }
        "2 pieces of feedback are waiting."
      end

      assert_match(/2 pieces of feedback are waiting\..*Place them/m, html)
    end

    should "raise on an unknown tone rather than render uncoloured" do
      assert_raises(KeyError) { render_alert(tone: :purple) }
    end
  end
end
