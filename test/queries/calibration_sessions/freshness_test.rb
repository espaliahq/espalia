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

  should "ignore writes about people outside the population" do
    create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
           person_id: @outsider.id, framework_id: @framework_id, manager_rated_frequency: "some")

    assert_nil freshness.stamp_token
  end
end
