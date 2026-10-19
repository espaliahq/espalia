# frozen_string_literal: true

require "test_helper"

class CalibrationSessions::FreshnessTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7
    @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)
    @em = create(:person, tenant: @tenant, name: "Mia")
    @report = create(:person, tenant: @tenant, name: "Ivy", manager: @em)
    @outsider = create(:person, tenant: @tenant, name: "Not In Session")
    @session = create(:calibration_session, tenant: @tenant, cycle_id: @cycle.cycle_id,
                      framework_id: @framework_id, status: "started")
    create(:calibration_session_member, tenant: @tenant, session: @session, person_id: @report.id)
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  def freshness
    CalibrationSessions::Freshness.new(session: @session)
  end

  should "have no stamp, and report no change, before anything is written" do
    assert_nil freshness.stamp_token
    assert_not freshness.call(since: nil)[:changed]
  end

  should "move with the population's evidence, and count the links written since" do
    since = travel_to(1.minute.ago) do
      create(:evidence_item, tenant: @tenant, person_id: @report.id, framework_id: @framework_id)
      freshness.stamp_token
    end
    create(:evidence_item, tenant: @tenant, person_id: @report.id, framework_id: @framework_id)

    result = freshness.call(since: since)
    assert result[:changed]
    assert_equal 1, result[:evidence_changed]
    assert_equal 0, result[:ratings_changed]
  end

  should "count a self-rating apart, credited to no rater" do
    role = create(:framework_role, tenant: @tenant)
    create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
           person_id: @report.id, level_ordinal: 3, role_id: role.role_id)
    category = create(:framework_capability_category, tenant: @tenant, framework_id: @framework_id)
    cap = create(:framework_capability, tenant: @tenant, category_id: category.category_id)
    create(:framework_capability_role_binding, tenant: @tenant, capability_id: cap.capability_id, role_id: role.role_id)
    create(:framework_behavioural_expectation, tenant: @tenant, capability_id: cap.capability_id, level_ordinal: 3)
    since = 1.minute.ago.utc.iso8601(6)
    create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: @report.id,
           framework_id: @framework_id, capability_stable_id: cap.stable_id, level_ordinal: 3,
           self_rated_frequency: "some", last_self_rated_at: Time.current)

    result = freshness.call(since: since)
    assert_equal 1, result[:self_ratings_changed]
    assert_equal 0, result[:ratings_changed], "the manager wrote nothing"
    assert_empty result[:by_rater]
  end

  should "ignore writes about people outside the population" do
    create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
           person_id: @outsider.id, framework_id: @framework_id, manager_rated_frequency: "some")

    assert_nil freshness.stamp_token
  end
end
