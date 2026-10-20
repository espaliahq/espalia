# frozen_string_literal: true

require "test_helper"

class Components::Kit::ButtonTest < ActiveSupport::TestCase
  Button = Components::Kit::Button

  def render_button(**options) = Nokogiri::HTML.fragment(Button.new(**options) { "Save" }.call).children.first

  context "Components::Kit::Button" do
    should "render a type=button by default" do
      button = render_button

      assert_equal "button", button.name
      assert_equal "button", button["type"]
      assert_equal "Save", button.text
    end

    should "carry each variant's class set and its tone" do
      Button::VARIANTS.each_key do |variant|
        classes = render_button(variant: variant, tone: :danger)["class"].split

        assert_includes classes, "tone-danger"
        assert_empty Button::VARIANTS[variant].split - classes, "#{variant} is missing its classes"
      end
    end

    should "render an a with href:" do
      link = render_button(href: "/frameworks")

      assert_equal "a", link.name
      assert_equal "/frameworks", link["href"]
      assert_nil link["type"]
    end

    should "drop the href of a disabled link and mark it aria-disabled" do
      link = render_button(href: "/frameworks", disabled: true)

      assert_nil link["href"]
      assert_equal "true", link["aria-disabled"]
    end

    should "disable a button natively" do
      assert render_button(disabled: true).key?("disabled")
    end

    should "raise for icon: without aria_label:" do
      assert_raises(ArgumentError) { Button.new(icon: true) }
    end

    should "name an icon button with aria_label:" do
      assert_equal "Edit", render_button(icon: true, aria_label: "Edit")["aria-label"]
    end

    should "append a caller's class and pass other attributes through" do
      button = render_button(class: "w-full", data: { action: "modal#open" }, aria: { expanded: "false" })

      assert button["class"].end_with?(" w-full")
      assert_equal "modal#open", button["data-action"]
      assert_equal "false", button["aria-expanded"]
    end

    should "match .classes to the rendered button" do
      options = { variant: :outline, tone: :brand, size: :sm, touch: true }

      assert_equal Button.classes(**options), render_button(**options)["class"]
    end
  end
end
