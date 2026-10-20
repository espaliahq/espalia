# frozen_string_literal: true

require "test_helper"

class Components::Kit::EmptyStateTest < ActiveSupport::TestCase
  context "Components::Kit::EmptyState" do
    should "render only the title when given no block" do
      html = Components::Kit::EmptyState.new(title: "No frameworks yet").call
      box = Nokogiri::HTML5.fragment(html).at_css("div")

      assert_equal "No frameworks yet", box.text
      assert_equal 1, box.css("p").size
    end

    should "render the body and then the action" do
      html = Components::Kit::EmptyState.new(title: "No frameworks yet").call do |empty|
        empty.action { "Create a framework" }
        "A framework sets out the roles people are rated on."
      end

      assert_match(/No frameworks yet.*rated on\..*Create a framework/m, html)
    end
  end
end
