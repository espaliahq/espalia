# frozen_string_literal: true

require "test_helper"

class RailsEventStoreConfigTest < ActiveSupport::TestCase
  context "Rails.configuration.event_store" do
    should "be configured and accessible" do
      event_store = Rails.configuration.event_store

      assert_not_nil event_store
      assert_kind_of RailsEventStore::JSONClient, event_store
    end

    should "publish and read events from a stream" do
      tenant = create(:tenant)
      event_store = Rails.configuration.event_store

      event = RubyEventStore::Event.new(
        data: { test: true },
        metadata: { tenant_id: tenant.id }
      )

      stream_name = "tenant-#{tenant.id}/Test-#{SecureRandom.uuid_v7}"
      event_store.publish(event, stream_name: stream_name)

      read_events = event_store.read.stream(stream_name).to_a
      assert_equal 1, read_events.length
      assert_equal event.event_id, read_events.first.event_id
      assert_equal({ test: true }, read_events.first.data)
      assert_equal tenant.id, read_events.first.metadata[:tenant_id]
    end
  end
end
