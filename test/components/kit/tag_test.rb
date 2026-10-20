# frozen_string_literal: true

require "test_helper"

class Components::Kit::TagTest < ActiveSupport::TestCase
  Tag = Components::Kit::Tag

  def render_tag(label = "Delivery", **options) = Nokogiri::HTML.fragment(Tag.new(label, **options).call).children.first

  context "Components::Kit::Tag" do
    should "render the label in a span" do
      tag = render_tag

      assert_equal "span", tag.name
      assert_equal "Delivery", tag.text
    end

    should "colour a numbered category with its own pair" do
      classes = render_tag(category: 3)["class"].split

      assert_includes classes, "bg-category-3"
      assert_includes classes, "text-category-3"
    end

    should "stay neutral without a category" do
      assert_not_includes render_tag["class"], "category"
    end

    should "hash a key to the same category every time" do
      category = Tag.category_for("capability-stable-id")

      assert_includes 1..8, category
      assert_equal category, Tag.category_for("capability-stable-id")
      assert_includes render_tag(category: "capability-stable-id")["class"].split, "bg-category-#{category}"
    end

    should "spread keys across the palette" do
      assert_equal 8, (1..200).map { |i| Tag.category_for("key-#{i}") }.uniq.size
    end

    should "raise for a numbered category outside 1–8" do
      assert_raises(ArgumentError) { Tag.new("x", category: 9) }
    end

    should "render leading and trailing icons around the label" do
      tag = render_tag(leading_icon: "pencil", trailing_icon: "chevron-down")
      uses = tag.css("svg use").map { |use| use["href"] }

      assert_equal %w[#icon-pencil #icon-chevron-down], uses
      assert_equal "Delivery", tag.text
    end

    should "append a caller's class and pass attributes through" do
      tag = render_tag(class: "ml-2", title: "Capability category")

      assert tag["class"].end_with?(" ml-2")
      assert_equal "Capability category", tag["title"]
    end
  end
end
