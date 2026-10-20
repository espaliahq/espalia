# frozen_string_literal: true

require "test_helper"

class FeedbackExchangeAckTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @item = create(:evidence_item, tenant: @tenant)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context "validations" do
    subject { build(:feedback_exchange_ack, tenant: @tenant) }

    should validate_presence_of(:consumer)
    should validate_presence_of(:remote_id)
    should validate_presence_of(:evidence_id)

    should "refuse a remote_url that is not http(s)" do
      assert_not build(:feedback_exchange_ack, tenant: @tenant, remote_url: "javascript:alert(1)").valid?
      assert_not build(:feedback_exchange_ack, tenant: @tenant, remote_url: "not a url").valid?
      assert build(:feedback_exchange_ack, tenant: @tenant, remote_url: nil).valid?
    end
  end

  context ".record_all" do
    should "store one row per item and consumer, updating on a repeat" do
      items = [ { id: @item.id, remote_id: "c-1", remote_url: "https://chip.example.com/f/1" } ]

      assert FeedbackExchangeAck.record_all(consumer: "Chip", items: items)
      assert FeedbackExchangeAck.record_all(consumer: "chip",
                                            items: [ { id: @item.id, remote_id: "c-2", remote_url: "https://chip.example.com/f/2" } ])

      ack = FeedbackExchangeAck.sole
      assert_equal "chip", ack.consumer
      assert_equal "c-2", ack.remote_id
      assert_equal "https://chip.example.com/f/2", ack.remote_url
      assert_equal @tenant.id, ack.tenant_id
    end

    should "keep a separate row for another consumer" do
      FeedbackExchangeAck.record_all(consumer: "chip", items: [ { id: @item.id, remote_id: "a" } ])
      FeedbackExchangeAck.record_all(consumer: "other", items: [ { id: @item.id, remote_id: "b" } ])

      assert_equal %w[chip other], FeedbackExchangeAck.order(:consumer).pluck(:consumer)
    end

    should "skip an id that is not one of the tenant's items" do
      assert FeedbackExchangeAck.record_all(consumer: "chip", items: [ { id: SecureRandom.uuid_v7, remote_id: "x" } ])
      assert_equal 0, FeedbackExchangeAck.count
    end

    should "ignore an item that belongs to another tenant" do
      other_tenant = create(:tenant)
      other = ActsAsTenant.with_tenant(other_tenant) { create(:evidence_item, tenant: other_tenant) }

      assert FeedbackExchangeAck.record_all(consumer: "chip", items: [ { id: other.id, remote_id: "x" } ])
      assert_equal 0, FeedbackExchangeAck.unscoped.count
    end

    should "write nothing when any item is malformed" do
      items = [ { id: @item.id, remote_id: "ok" }, { id: @item.id, remote_id: "" } ]

      assert_not FeedbackExchangeAck.record_all(consumer: "chip", items: items)
      assert_equal 0, FeedbackExchangeAck.count
    end

    should "refuse more items than a page holds" do
      items = Array.new(FeedbackExchangeAck::MAX_ITEMS + 1) { { id: @item.id, remote_id: "x" } }

      assert_not FeedbackExchangeAck.record_all(consumer: "chip", items: items)
    end
  end
end
