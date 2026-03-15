# frozen_string_literal: true

require "test_helper"

class Frameworks::CommandHandlerTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @framework_id = SecureRandom.uuid_v7
    @event_store = Rails.configuration.event_store
  end

  context "#create_framework" do
    should "publish FrameworkCreated event and create read model" do
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        handler.create_framework(@framework_id, "Engineering Growth")

        # Verify event in stream
        stream = EventStreamNaming.framework_stream(@framework_id)
        events = @event_store.read.stream(stream).to_a
        assert_equal 1, events.length
        assert_kind_of Frameworks::Events::FrameworkCreated, events.first
        assert_equal "Engineering Growth", events.first.data[:name]

        # Verify read model created by projection
        read_model = FrameworkState::Framework.find_by(framework_id: @framework_id)
        assert_not_nil read_model
        assert_equal "Engineering Growth", read_model.name
        assert_equal @tenant.id, read_model.tenant_id
      end
    end
  end
end
