# frozen_string_literal: true

require "test_helper"

class TeamPlanning::SyncHandlers::DeletedPlanKeysTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @plan_id = SecureRandom.uuid_v7
    @plan_key = PlanKeyStore.plan_identifier(@tenant.id, @plan_id)
    ActsAsTenant.with_tenant(@tenant) { PlanKeyStore.new.create(@plan_key) }
  end

  should "destroy the plan's keys for any writer of PlanDeleted, and destroy nothing more the second time" do
    event = TeamPlanning::Events::PlanDeleted.new(data: { plan_id: @plan_id, deleted_by_id: SecureRandom.uuid_v7 })
    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      Rails.configuration.event_store.publish(event, stream_name: "test-#{@plan_id}")
    end

    ActsAsTenant.with_tenant(@tenant) { assert_nil PlanKeyStore.new.key_of(@plan_key) }
    assert_nothing_raised { TeamPlanning::SyncHandlers::DeletedPlanKeys.new.call(event) }
  end
end
