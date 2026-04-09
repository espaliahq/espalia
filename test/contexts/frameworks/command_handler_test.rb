# frozen_string_literal: true

require "test_helper"

class Frameworks::CommandHandlerTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @framework_id = SecureRandom.uuid_v7
    @event_store = Rails.configuration.event_store
  end

  context "#create_framework" do
    should "publish FrameworkCreated + bootstrap DraftVersionStarted and create read model" do
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        handler.create_framework(@framework_id, "Engineering Growth")

        # Verify both events in stream (create bootstraps a v1 draft)
        stream = EventStreamNaming.framework_stream(@framework_id)
        events = @event_store.read.stream(stream).to_a
        assert_equal 2, events.length
        assert_kind_of Frameworks::Events::FrameworkCreated, events[0]
        assert_equal "Engineering Growth", events[0].data[:name]
        assert_kind_of Frameworks::Events::DraftVersionStarted, events[1]
        assert_equal 1, events[1].data[:target_version]
        assert_equal "system", events[1].data[:started_by]

        # Verify read model created by projection — in a bootstrap draft
        read_model = FrameworkState::Framework.find_by(framework_id: @framework_id)
        assert_not_nil read_model
        assert_equal "Engineering Growth", read_model.name
        assert_equal @tenant.id, read_model.tenant_id
        assert read_model.draft_in_progress
        assert_equal 1, read_model.draft_version
        assert_equal 0, read_model.current_published_version
      end
    end
  end

  context "full lifecycle integration" do
    should "build a complete framework through commands and verify read models" do
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        rfid = SecureRandom.uuid_v7
        rid = SecureRandom.uuid_v7
        lid = SecureRandom.uuid_v7
        cat_id = SecureRandom.uuid_v7
        cap_id = SecureRandom.uuid_v7
        stable_id = SecureRandom.uuid_v7
        bid = SecureRandom.uuid_v7
        eid = SecureRandom.uuid_v7
        exp_stable_id = SecureRandom.uuid_v7
        iid = SecureRandom.uuid_v7

        # create_framework bootstraps a v1 draft, so shape-changing commands
        # are available immediately.
        handler.create_framework(@framework_id, "me&u 2025")
        handler.add_role_family(@framework_id, rfid, "Data", description: "Data team roles")
        handler.add_role(@framework_id, rid, rfid, "Data Engineer", "DE", "ic")
        handler.add_level(@framework_id, lid, rid, 1, "Associate Data Engineer", "DE1", is_entry: true)
        handler.add_capability_category(@framework_id, cat_id, "Thinking & Delivery", description: "How we think", ordinal: 1)
        handler.add_capability(@framework_id, cap_id, stable_id, cat_id, "Strategic Thinking", description: "Long-term thinking")
        handler.create_capability_role_binding(@framework_id, bid, cap_id, rid, weight: 1.0)
        handler.set_behavioural_expectation(@framework_id, eid, exp_stable_id, cap_id, 1, "Asks questions to understand problems.")
        handler.add_role_illustration(@framework_id, iid, SecureRandom.uuid_v7, eid, rid, 1, "Seeks guidance from a data lead")

        # Shape-changing events are deferred during the bootstrap draft.
        # Verify that they are not visible until publish_version.
        assert_nil FrameworkState::Capability.find_by(capability_id: cap_id)
        assert_nil FrameworkState::Level.find_by(level_id: lid)

        # Publish v1 — rebuild replays all events, making shape-changing
        # events visible in the published projection.
        handler.publish_version(@framework_id, "seed")

        # Verify event stream: 1 FrameworkCreated + 1 DraftVersionStarted
        # (bootstrap) + 9 commands + 1 FrameworkVersionPublished = 11 events
        stream = EventStreamNaming.framework_stream(@framework_id)
        events = @event_store.read.stream(stream).to_a
        assert_equal 11, events.length

        # Verify all read models
        assert_equal 1, FrameworkState::Framework.count
        assert_equal 1, FrameworkState::RoleFamily.count
        assert_equal 1, FrameworkState::Role.count
        assert_equal 1, FrameworkState::Level.count
        assert_equal 1, FrameworkState::CapabilityCategory.count
        assert_equal 1, FrameworkState::Capability.count
        assert_equal 1, FrameworkState::CapabilityRoleBinding.count
        assert_equal 1, FrameworkState::BehaviouralExpectation.count
        assert_equal 1, FrameworkState::RoleIllustration.count

        # Verify associations work
        framework = FrameworkState::Framework.find_by!(framework_id: @framework_id)
        assert_equal 1, framework.current_published_version
        assert_not framework.draft_in_progress
        assert_equal "Data", framework.role_families.first.name
        assert_equal "Data Engineer", framework.role_families.first.roles.first.name

        capability = FrameworkState::Capability.find_by!(capability_id: cap_id)
        expectation = capability.expectations.first
        assert_equal "Asks questions to understand problems.", expectation.description
        assert_equal "Seeks guidance from a data lead", expectation.illustrations.first.description

        # Verify tenant metadata on events
        events.each do |event|
          assert_equal @tenant.id, event.metadata[:tenant_id]
        end
      end
    end
  end
end
