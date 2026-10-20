# frozen_string_literal: true

require "test_helper"

class Views::Assessments::Evidence::CardOriginTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def render_card(reference)
    item = build(:evidence_item, id: SecureRandom.uuid_v7, tenant: @tenant, author: create(:person, tenant: @tenant, name: "Priya"),
                                 external_reference: reference, recorded_at: 2.days.ago)
    card = Views::Assessments::Evidence::Card.new(item: item, assessment_id: SecureRandom.uuid_v7,
      current_capability_stable_id: item.capability_stable_id, current_level_ordinal: item.level_ordinal)
    html = ApplicationController.render(card, layout: false)
    Nokogiri::HTML5.fragment(html)
  end

  should "say an imported item was given in the peer, in place of the plain link chip" do
    html = render_card({ system: "chip", url: "https://chip.example.com/f/1", metadata: { "given_at" => "2026-10-18T03:12:44Z" } })
    assert_equal "https://chip.example.com/f/1", html.at_css("a[data-origin='chip']")["href"]
    assert_not_includes html.text, "chip↗"
  end

  should "keep the plain chip for a reference someone attached" do
    html = render_card({ system: "github", url: "https://github.com/o/r/pull/1" })
    assert_nil html.at_css("[data-origin]")
    assert_equal "github", html.at_css("a[href='https://github.com/o/r/pull/1']").text
  end
end
