# frozen_string_literal: true

require "test_helper"

class Components::Kit::CardTest < ActiveSupport::TestCase
  context "Components::Kit::Card" do
    should "render the title as an h3 by default" do
      html = Components::Kit::Card.new(title: "Stats").call { |c| c.body { } }
      assert_match(/<h3[^>]*>Stats<\/h3>/, html)
    end

    should "honour an explicit heading level for sequential document outline" do
      html = Components::Kit::Card.new(title: "Awaiting you", heading_level: :h2).call { |c| c.body { } }
      assert_match(/<h2[^>]*>Awaiting you<\/h2>/, html)
      assert_no_match(/<h3/, html)
    end
  end
end
