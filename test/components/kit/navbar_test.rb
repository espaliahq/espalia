# frozen_string_literal: true

require "test_helper"

class Components::Kit::NavbarTest < ActiveSupport::TestCase
  context "the brand" do
    setup do
      @html = Components::Kit::Navbar.new(app_name: "GrowthOS").call
    end

    should "be a button wired to the confetti controller" do
      assert_includes @html, %(data-controller="brand-confetti")
      assert_includes @html, %(data-brand-confetti-target="brand")
      assert_includes @html, "click->brand-confetti#celebrate"
    end

    should "describe itself with the tagline tooltip" do
      assert_includes @html, %(aria-describedby="brand-tagline")
      assert_includes @html, %(id="brand-tagline")
      assert_includes @html, %(role="tooltip")
      assert_includes @html, "not just a tool, but a way of life 🫶"
    end

    should "set the tagline in Comic Sans so nobody mistakes it for the real design" do
      assert_includes @html, "Comic Sans MS"
    end
  end
end
