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

    should "pad a default card's body on every side when it has no title" do
      html = Components::Kit::Card.new.call { |c| c.body { "x" } }
      assert_includes html, '<div class="px-6 pb-6 pt-6">x</div>'
    end

    should "leave a flush card's body unpadded, title or not" do
      untitled = Components::Kit::Card.new(variant: :flush).call { |c| c.body { "x" } }
      titled = Components::Kit::Card.new(variant: :flush, title: "Users").call { |c| c.body { "x" } }

      assert_includes untitled, "<div>x</div>"
      assert_includes titled, "<div>x</div>"
    end

    should "lay an inset panel flat, with no shadow" do
      html = Components::Kit::Card.new(variant: :inset).call { |c| c.body { "x" } }
      assert_no_match(/shadow-/, html)
    end

    should "swap the default edge for the one it is given" do
      html = Components::Kit::Card.new(variant: :inset, edge: "border-warning").call { |c| c.body { "x" } }
      assert_includes html, "border-warning"
      assert_not_includes html, "border-default"
    end

    should "pad a compact card tighter than a regular one" do
      regular = Components::Kit::Card.new(title: "T").call { |c| c.body { "x" } }
      compact = Components::Kit::Card.new(title: "T", density: :compact).call { |c| c.body { "x" } }
      assert_not_equal regular, compact
      assert_equal regular.gsub(/class="[^"]*"/, ""), compact.gsub(/class="[^"]*"/, "")
    end

    should "render as a link to its href, title and all" do
      html = Components::Kit::Card.new(title: "People", href: "/tenant/users").call { |c| c.body { "x" } }
      assert_match(%r{\A<a href="/tenant/users"[^>]*>.*<h3[^>]*>People</h3>.*</a>\z}m, html)
    end

    should "give an interactive card the link's hover and focus treatment on a div" do
      link = Components::Kit::Card.new(href: "#").call
      div = Components::Kit::Card.new(interactive: true).call
      assert_equal link[/class="([^"]*)"/, 1], div[/class="([^"]*)"/, 1]
      assert div.start_with?("<div")
      assert_not_equal Components::Kit::Card.new.call[/class="([^"]*)"/, 1], div[/class="([^"]*)"/, 1]
    end

    should "pass extra attributes to the root" do
      html = Components::Kit::Card.new(id: "scoring-panel", data: { focused: "true" }).call
      assert_match(/\A<div [^>]*id="scoring-panel" data-focused="true"/, html)
    end
  end
end
