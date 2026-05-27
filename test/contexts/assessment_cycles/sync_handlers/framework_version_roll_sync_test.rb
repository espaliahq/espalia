# frozen_string_literal: true

require "test_helper"

class AssessmentCycles::SyncHandlers::FrameworkVersionRollSyncTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = AssessmentCycles::SyncHandlers::FrameworkVersionRollSync.new

    @framework_id = SecureRandom.uuid_v7
    cycle_handler = AssessmentCycles::CommandHandler.new

    # `idx_assessment_cycles_one_open_per_framework` permits only one
    # open cycle per (tenant, framework) — so to exercise the
    # closed-cycle-is-skipped path we close the first cycle BEFORE
    # opening the second one on the same framework.
    @closed_cycle = SecureRandom.uuid_v7
    cycle_handler.define_cycle(@closed_cycle, @framework_id, "C", "regular", 1)
    cycle_handler.close_cycle(@closed_cycle)

    @open_cycle = SecureRandom.uuid_v7
    cycle_handler.define_cycle(@open_cycle, @framework_id, "A", "regular", 1)

    @other_framework_cycle = SecureRandom.uuid_v7
    cycle_handler.define_cycle(@other_framework_cycle, SecureRandom.uuid_v7, "D", "regular", 1)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def publish_event(version: 2)
    Frameworks::Events::FrameworkVersionPublished.new(
      data: { framework_id: @framework_id, version: version, published_by: "tester" },
      metadata: { tenant_id: @tenant.id }
    )
  end

  context "on FrameworkVersionPublished" do
    should "roll the open cycle of the published framework" do
      @handler.call(publish_event)

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal 2, AssessmentCycle.find_by(cycle_id: @open_cycle).latest_framework_version
      end
    end

    should "leave closed cycles untouched" do
      @handler.call(publish_event)

      ActsAsTenant.with_tenant(@tenant) do
        closed = AssessmentCycle.find_by(cycle_id: @closed_cycle)
        assert_equal 1, closed.latest_framework_version, "closed cycles freeze the version range"
      end
    end

    should "leave cycles for other frameworks untouched" do
      @handler.call(publish_event)

      ActsAsTenant.with_tenant(@tenant) do
        other = AssessmentCycle.find_by(cycle_id: @other_framework_cycle)
        assert_equal 1, other.latest_framework_version
      end
    end

    should "be idempotent — replay is a no-op via the aggregate guard" do
      @handler.call(publish_event)
      @handler.call(publish_event)

      stream = EventStreamNaming.assessment_cycle_stream(@open_cycle)
      rolled_events = Rails.configuration.event_store.read.stream(stream).to_a
        .select { |e| e.is_a?(AssessmentCycles::Events::FrameworkVersionRolled) }
      assert_equal 1, rolled_events.size
    end
  end
end
