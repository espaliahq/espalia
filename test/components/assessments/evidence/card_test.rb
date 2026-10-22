# frozen_string_literal: true

require "test_helper"

class Views::Assessments::Evidence::CardTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @item = create(:evidence_item, tenant: @tenant)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def render_card
    html = view_context.render(Views::Assessments::Evidence::Card.new(
      item: @item, assessment_id: SecureRandom.uuid_v7,
      current_capability_stable_id: @item.capability_stable_id, current_level_ordinal: @item.level_ordinal
    ))
    Nokogiri::HTML5.fragment(html)
  end

  def view_context
    @view_context ||= ApplicationController.new.tap do |controller|
      controller.request = ActionDispatch::TestRequest.create
    end.view_context
  end

  context "the Also in link" do
    should "link to where the peer holds the item" do
      @item.exchange_acks = [ build(:feedback_exchange_ack, tenant: @tenant, consumer: "chip", remote_url: "https://chip.example.com/f/9") ]

      link = render_card.at_css("a[data-exchange-ack='chip']")

      assert_equal "Also in Chip (opens in a new tab)", link.text
      assert_equal "https://chip.example.com/f/9", link["href"]
      assert_equal "_blank", link["target"]
      assert_includes link["rel"], "noopener"
    end

    should "name the peer without a link when it gave no address" do
      @item.exchange_acks = [ build(:feedback_exchange_ack, tenant: @tenant, consumer: "chip", remote_url: nil) ]

      chip = render_card.at_css("[data-exchange-ack='chip']")

      assert_equal "Also in Chip", chip.text
      assert_equal "span", chip.name
    end

    should "never link to an address that is not http(s)" do
      @item.exchange_acks = [ build(:feedback_exchange_ack, tenant: @tenant, consumer: "chip", remote_url: "javascript:alert(1)") ]

      chip = render_card.at_css("[data-exchange-ack='chip']")

      assert_equal "span", chip.name
      assert_nil chip["href"]
    end

    should "be absent for an item no peer holds" do
      @item.exchange_acks = []
      assert_nil render_card.at_css("[data-exchange-ack]")

      @item.exchange_acks = nil
      assert_nil render_card.at_css("[data-exchange-ack]")
    end
  end

  should "load acknowledgements for a page of items in one query" do
    other = create(:evidence_item, tenant: @tenant)
    create(:feedback_exchange_ack, tenant: @tenant, evidence_id: @item.id, consumer: "chip")

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      EvidenceItem.load_exchange_acks([ @item, other ])
    end

    assert_equal 1, queries
    assert_equal %w[chip], @item.exchange_acks.map(&:consumer)
    assert_empty other.exchange_acks
  end
end
