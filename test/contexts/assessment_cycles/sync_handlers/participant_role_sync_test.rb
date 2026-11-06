# frozen_string_literal: true

require "test_helper"

class AssessmentCycles::SyncHandlers::ParticipantRoleSyncTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = AssessmentCycles::SyncHandlers::ParticipantRoleSync.new
    @pd = PersonDevelopment::CommandHandler.new
    @cycles = AssessmentCycles::CommandHandler.new

    @framework_id = SecureRandom.uuid_v7
    @person_id = SecureRandom.uuid_v7
    rf = create(:framework_role_family, framework_id: @framework_id)
    @role = create(:framework_role, role_family_id: rf.role_family_id, code: "E", track: "ic")
    @level1 = create(:framework_level, role_id: @role.role_id, ordinal: 1, title: "E1", code: "E1")
    @level2 = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "E2", code: "E2")

    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      @pd.assign_to_framework(@person_id, @framework_id, @role.role_id, @level1.level_id)
      @cycle_id = SecureRandom.uuid_v7
      @cycles.define_cycle(@cycle_id, @framework_id, "Q1", "regular", 1)
      @cycles.enroll(@cycle_id, @person_id, role_id: @role.role_id, level_id: @level1.level_id)
    end
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def level_changed_event(new_level_id, framework_id: @framework_id)
    PersonDevelopment::Events::PersonLevelChanged.new(
      data: { previous_level_id: @level1.level_id, new_level_id: new_level_id, reason: "promotion" },
      metadata: { tenant_id: @tenant.id, person_id: @person_id, framework_id: framework_id }
    )
  end

  def enrollment
    AssessmentCycleEnrollment.find_by(cycle_id: @cycle_id, person_id: @person_id)
  end

  should "snapshot the enrollment at the assessed level on enroll" do
    assert_equal @level1.level_id, enrollment.level_id
    assert_equal 1, enrollment.level_ordinal
  end

  should "re-snapshot the open cycle's enrollment level on a mid-cycle promotion" do
    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      @handler.call(level_changed_event(@level2.level_id))
    end

    assert_equal @level2.level_id, enrollment.level_id
    assert_equal 2, enrollment.level_ordinal
  end

  should "keep the snapshot once alignment has started" do
    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      @pd.start_alignment(@person_id, @framework_id, @cycle_id, started_by_id: create(:person, tenant: @tenant).id)
      @handler.call(level_changed_event(@level2.level_id))
    end

    assert_equal @level1.level_id, enrollment.level_id
    assert_equal 1, enrollment.level_ordinal
  end

  should "no-op when the change is for a framework with no open enrolled cycle" do
    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      @handler.call(level_changed_event(@level2.level_id, framework_id: SecureRandom.uuid_v7))
    end

    # The real cycle's snapshot is untouched.
    assert_equal @level1.level_id, enrollment.level_id
  end
end
