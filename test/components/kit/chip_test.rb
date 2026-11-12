# frozen_string_literal: true

require "test_helper"

class Components::Kit::ChipTest < ActiveSupport::TestCase
  Chip = Components::Kit::Chip

  def render_chip(label = "This cycle", **options) = Nokogiri::HTML.fragment(Chip.new(label, **options).call).children.first

  context "a toggle chip" do
    should "be a type=button with aria-pressed false at rest" do
      chip = render_chip

      assert_equal "button", chip.name
      assert_equal "button", chip["type"]
      assert_equal "false", chip["aria-pressed"]
      assert_equal "This cycle", chip.text
    end

    should "carry aria-pressed true when pressed" do
      assert_equal "true", render_chip(pressed: true)["aria-pressed"]
    end

    should "disable natively" do
      assert render_chip(disabled: true).key?("disabled")
    end

    should "come in a small size for a dense row, still a 24px target" do
      classes = render_chip("E3", size: :sm)["class"].split

      assert_includes classes, "min-h-6"
      assert_not_includes classes, "min-h-8"
    end

    should "keep a caller's aria and data alongside aria-pressed" do
      chip = render_chip(data: { action: "filter#toggle" }, aria: { controls: "results" })

      assert_equal "filter#toggle", chip["data-action"]
      assert_equal "results", chip["aria-controls"]
      assert_equal "false", chip["aria-pressed"]
    end
  end

  context "a removable chip" do
    should "wrap the label and a remove button named for it" do
      chip = render_chip("Aisha Khan", remove: { data: { action: "picker#remove" } })
      button = chip.at_css("button")

      assert_equal "span", chip.name
      assert_nil chip["aria-pressed"]
      assert_equal "Remove Aisha Khan", button["aria-label"]
      assert_equal "picker#remove", button["data-action"]
      assert_equal "true", button.at_css("svg")["aria-hidden"]
    end

    should "take a custom accessible name for the remove button" do
      chip = render_chip("E3", remove: {}, remove_label: "Remove level E3")

      assert_equal "Remove level E3", chip.at_css("button")["aria-label"]
    end

    should "disable the remove button" do
      assert render_chip(remove: {}, disabled: true).at_css("button").key?("disabled")
    end
  end
end
