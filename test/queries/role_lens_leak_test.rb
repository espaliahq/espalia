# frozen_string_literal: true

require "test_helper"

# Phase 1's leak tests used rows written straight into the read model; these
# feed the same readers with a real write through a role lens (ADR-22). A
# self rating on a cell only the lens role reads must count nowhere on the
# record, and a rating made through the lens on a shared cell must count
# exactly like any other — the lens is provenance, never a scope.
class RoleLensLeakTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @fx = build_role_lens_framework(tenant: @tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @manager_user = create(:user)
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Morgan")
      @manager_tenant_user = create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @user = create(:user)
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Alex", manager: @manager)
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @person)
    end
    @assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    ActsAsTenant.current_tenant = @tenant
    @cycle = AssessmentCycle.find_by!(cycle_id: @cycle_id)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context "a self rating on a cell only the lens role reads" do
    setup do
      rate(Operations::Assessments::RateSelf, as_assessee, @fx.pm_only)
    end

    should "not count toward the record's coverage" do
      coverage = Assessments::LevelCoverage.new(person_id: @person.id, framework_id: @fx.framework_id,
                                                cycle_id: @cycle_id).call
      assert_equal 0, coverage[:self_rated]
    end

    should "not count in the cohort report" do
      assert_equal 0, Reporting::CycleCohort.new(cycle: @cycle).call.participants.first.self_count
    end

    should "not reach the capability attainment report" do
      result = Reporting::CapabilityAttainment.new(cycle: @cycle, perspective: :self_only).call
      assert_not_includes result.capabilities.map(&:stable_id), @fx.pm_only.stable_id
    end
  end

  context "a rating made through the lens on a shared cell" do
    setup do
      rate(Operations::Assessments::RateSelf, as_assessee, @fx.shared)
      rate(Operations::Assessments::RateAsManager, as_manager, @fx.shared)
    end

    should "count on the record like any other" do
      participant = Reporting::CycleCohort.new(cycle: @cycle).call.participants.first
      assert_equal [ 1, 1 ], [ participant.self_count, participant.manager_count ]
    end

    should "count in a calibration room reading the home role" do
      session = create(:calibration_session, tenant: @tenant, cycle_id: @cycle_id,
                       framework_id: @fx.framework_id, facilitator_id: @manager.id, status: "started")
      create(:calibration_session_member, :participant, tenant: @tenant, session: session, person_id: @manager.id)
      create(:calibration_session_member, tenant: @tenant, session: session, person_id: @person.id)

      dot = CalibrationSessions::CohortScores.new(session: session).call[:cohorts]
        .flat_map { |cohort| cohort[:people] }.find { |person| person[:person_id] == @person.id }
      assert_equal [ 1, 2 ], dot.values_at(:rated, :total)
    end
  end

  # A declared exploration is an intent, not a cycle (ADR-22): declaring and
  # closing one touches no rating, no participation and no cohort number.
  context "a declared exploration" do
    setup do
      @before = cohort_numbers
      @status_before = progress_status
      result = Operations::Assessments::StartExploration.call(
        context: as_assessee, params: { assignment_id: @assignment.id, as_role_id: @fx.pm.role_id }
      )
      Operations::Assessments::CloseExploration.call(
        context: as_manager, params: { assignment_id: @assignment.id, exploration_id: result[:id], outcome: "pursue" }
      )
      Operations::Assessments::StartExploration.call(
        context: as_manager, params: { assignment_id: @assignment.id, as_role_id: @fx.pm.role_id }
      )
    end

    should "leave the cohort report, the participation and the ratings as they were" do
      assert_equal @before, cohort_numbers
      assert_equal @status_before, progress_status
      assert_equal 0, AssessmentLevelRating.across_all_roles.where(person_id: @person.id).count
    end
  end

  private

  def progress_status
    AssessmentCycleProgress.find_by!(cycle_id: @cycle_id, person_id: @person.id).status
  end

  def cohort_numbers
    Reporting::CycleCohort.new(cycle: @cycle).call.participants.map do |participant|
      [ participant.self_count, participant.manager_count, participant.status ]
    end
  end

  def as_assessee
    AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def as_manager
    AuthorizationContext.new(user: @manager_user, tenant_user: @manager_tenant_user, person: @manager)
  end

  def rate(operation, context, capability)
    operation.call(context: context, params: {
      assignment_id: @assignment.id, capability_stable_id: capability.stable_id, level_ordinal: 2,
      frequency: "consistent", as_role_id: @fx.pm.role_id
    })
  end
end
