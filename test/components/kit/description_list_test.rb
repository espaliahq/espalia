# frozen_string_literal: true

require "test_helper"

class Components::Kit::DescriptionListTest < ActiveSupport::TestCase
  DescriptionList = Components::Kit::DescriptionList

  def render_list(**options)
    Nokogiri::HTML.fragment(DescriptionList.new(items: [ { term: "Roles", detail: "11" } ], **options).call).children.first
  end

  context "Components::Kit::DescriptionList" do
    should "render each term and detail" do
      list = render_list

      assert_equal "dl", list.name
      assert_equal "Roles", list.at_css("dt").text
      assert_equal "11", list.at_css("dd").text
    end

    should "default to three columns from sm up" do
      assert_includes render_list["class"].split, "sm:grid-cols-3"
    end

    (1..4).each do |count|
      should "spell out sm:grid-cols-#{count} for #{count} columns" do
        classes = render_list(columns: count)["class"].split

        assert_includes classes, "grid-cols-1"
        assert_includes classes, "sm:grid-cols-#{count}"
      end
    end

    should "raise for an unsupported column count" do
      assert_raises(ArgumentError) { DescriptionList.new(items: [], columns: 5) }
      assert_raises(ArgumentError) { DescriptionList.new(items: [], columns: "3") }
    end
  end
end
