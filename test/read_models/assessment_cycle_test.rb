# frozen_string_literal: true

require "test_helper"

class AssessmentCycleTest < ActiveSupport::TestCase
  context ".open_cycles_for" do
    setup do
      @tenant = create(:tenant)
      ActsAsTenant.current_tenant = @tenant
    end

    teardown do
      ActsAsTenant.current_tenant = nil
    end

    should "return an empty hash for an empty input" do
      assert_equal({}, AssessmentCycle.open_cycles_for([]))
    end

    should "return a map keyed by [framework_id, person_id]" do
      fw_id = SecureRandom.uuid_v7
      person_id = SecureRandom.uuid_v7
      cycle = create(:assessment_cycle, tenant: @tenant, framework_id: fw_id)
      create(:assessment_cycle_participant,
        tenant: @tenant, cycle: cycle, person_id: person_id)

      result = AssessmentCycle.open_cycles_for([ [ fw_id, person_id ] ])

      assert_equal cycle.id, result[[ fw_id, person_id ]].id
    end

    should "exclude closed cycles" do
      fw_id = SecureRandom.uuid_v7
      person_id = SecureRandom.uuid_v7
      cycle = create(:assessment_cycle, :closed, tenant: @tenant, framework_id: fw_id)
      create(:assessment_cycle_participant,
        tenant: @tenant, cycle: cycle, person_id: person_id)

      assert_equal({}, AssessmentCycle.open_cycles_for([ [ fw_id, person_id ] ]))
    end

    should "exclude withdrawn participants" do
      fw_id = SecureRandom.uuid_v7
      person_id = SecureRandom.uuid_v7
      cycle = create(:assessment_cycle, tenant: @tenant, framework_id: fw_id)
      create(:assessment_cycle_participant, :withdrawn,
        tenant: @tenant, cycle: cycle, person_id: person_id)

      assert_equal({}, AssessmentCycle.open_cycles_for([ [ fw_id, person_id ] ]))
    end

    should "handle multiple people in the same cycle" do
      fw_id = SecureRandom.uuid_v7
      p1 = SecureRandom.uuid_v7
      p2 = SecureRandom.uuid_v7
      cycle = create(:assessment_cycle, tenant: @tenant, framework_id: fw_id)
      create(:assessment_cycle_participant, tenant: @tenant, cycle: cycle, person_id: p1)
      create(:assessment_cycle_participant, tenant: @tenant, cycle: cycle, person_id: p2)

      result = AssessmentCycle.open_cycles_for([ [ fw_id, p1 ], [ fw_id, p2 ] ])

      assert_equal cycle.id, result[[ fw_id, p1 ]].id
      assert_equal cycle.id, result[[ fw_id, p2 ]].id
    end

    should "ignore cycles for frameworks not in the request" do
      p1 = SecureRandom.uuid_v7
      fw1 = SecureRandom.uuid_v7
      fw2 = SecureRandom.uuid_v7
      cycle1 = create(:assessment_cycle, tenant: @tenant, framework_id: fw1)
      cycle2 = create(:assessment_cycle, tenant: @tenant, framework_id: fw2)
      create(:assessment_cycle_participant, tenant: @tenant, cycle: cycle1, person_id: p1)
      create(:assessment_cycle_participant, tenant: @tenant, cycle: cycle2, person_id: p1)

      result = AssessmentCycle.open_cycles_for([ [ fw1, p1 ] ])

      assert_equal 1, result.size
      assert_equal cycle1.id, result[[ fw1, p1 ]].id
    end
  end
end
