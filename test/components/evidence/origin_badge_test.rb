# frozen_string_literal: true

require "test_helper"

class Views::Evidence::OriginBadgeTest < ActiveSupport::TestCase
  def imported(**attributes)
    ExternalReference.new({ system: "chip", external_id: "c-1", url: "https://chip.example.com/feedback/c-1",
                            metadata: { "given_at" => "2026-10-18T03:12:44Z" } }.merge(attributes))
  end

  def render_badge(reference, **options) = Nokogiri::HTML5.fragment(Views::Evidence::OriginBadge.new(reference, **options).call)

  should "name the peer and open the original in a new tab" do
    link = render_badge(imported).at_css("a")
    assert_equal "via Chip ↗ (opens in a new tab)", link.text
    assert_equal "https://chip.example.com/feedback/c-1", link["href"]
    assert_equal "_blank", link["target"]
    assert_equal "noopener noreferrer", link["rel"]
    assert_equal "chip", link["data-origin"]
  end

  should "be plain text when the peer sent no safe link" do
    html = render_badge(imported(url: nil))
    assert_nil html.at_css("a")
    assert_equal "via Chip", html.at_css("span[data-origin='chip']").text
  end

  should "name a peer it has no label for from its slug" do
    assert_includes render_badge(imported(system: "kudos-board")).text, "via Kudos Board"
  end

  should "name a peer that shares a link target's slug as that peer, not GrowthOS" do
    assert_includes render_badge(imported(system: "slack")).text, "via Slack"
  end

  context "ExternalReference#imported?" do
    should "be true only for a reference the exchange importer wrote" do
      assert imported.imported?
      assert_not ExternalReference.new(system: "github", url: "https://github.com/o/r/pull/1").imported?
      assert_not ExternalReference.new(metadata: { "given_at" => "2026-10-18T03:12:44Z" }).imported?
    end
  end
end
