# frozen_string_literal: true

require "test_helper"

class AssessmentCycleParticipationTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @cycle = create(:assessment_cycle, tenant: @tenant)
    @person_id = SecureRandom.uuid_v7
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context "#status (derived from enrollment + progress)" do
    should "returns 'enrolled' when only enrollment exists" do
      enrollment = create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)

      participation = AssessmentCycleParticipation.new(enrollment: enrollment)
      assert_equal "enrolled", participation.status
    end

    should "returns 'enrolled' when progress is in_progress with no started_at" do
      enrollment = create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)
      progress = create(:assessment_cycle_progress,
        tenant: @tenant, cycle: @cycle, person_id: @person_id, status: "in_progress")

      participation = AssessmentCycleParticipation.new(enrollment: enrollment, progress: progress)
      assert_equal "enrolled", participation.status
    end

    should "returns 'started' when progress.status is started" do
      enrollment = create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)
      progress = create(:assessment_cycle_progress, :started,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)

      participation = AssessmentCycleParticipation.new(enrollment: enrollment, progress: progress)
      assert_equal "started", participation.status
    end

    should "returns 'aligning' when progress.status is aligning" do
      enrollment = create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)
      progress = create(:assessment_cycle_progress, :aligning,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)

      participation = AssessmentCycleParticipation.new(enrollment: enrollment, progress: progress)
      assert_equal "aligning", participation.status
    end

    should "returns 'aligned' when progress.status is aligned" do
      enrollment = create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)
      progress = create(:assessment_cycle_progress, :aligned,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)

      participation = AssessmentCycleParticipation.new(enrollment: enrollment, progress: progress)
      assert_equal "aligned", participation.status
    end

    should "returns 'withdrawn' when enrollment is withdrawn regardless of progress" do
      enrollment = create(:assessment_cycle_enrollment, :withdrawn,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)
      progress = create(:assessment_cycle_progress, :aligned,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)

      participation = AssessmentCycleParticipation.new(enrollment: enrollment, progress: progress)
      assert_equal "withdrawn", participation.status
    end

    should "returns 'concluded' when the cycle closed around the participant" do
      enrollment = create(:assessment_cycle_enrollment, :concluded,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)
      progress = create(:assessment_cycle_progress, :aligned,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)

      participation = AssessmentCycleParticipation.new(enrollment: enrollment, progress: progress)
      assert_equal "concluded", participation.status
    end
  end

  context "#individual_ratings_editable?" do
    should "true while enrolled or started" do
      enrollment = create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle, person_id: @person_id)
      assert AssessmentCycleParticipation.new(enrollment: enrollment).individual_ratings_editable?

      progress = create(:assessment_cycle_progress, :started,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)
      assert AssessmentCycleParticipation.new(enrollment: enrollment, progress: progress).individual_ratings_editable?
    end

    should "false once aligning" do
      enrollment = create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle, person_id: @person_id)
      progress = create(:assessment_cycle_progress, :aligning,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)

      participation = AssessmentCycleParticipation.new(enrollment: enrollment, progress: progress)
      assert_not participation.individual_ratings_editable?
    end

    should "false when withdrawn" do
      enrollment = create(:assessment_cycle_enrollment, :withdrawn, tenant: @tenant, cycle: @cycle, person_id: @person_id)
      assert_not AssessmentCycleParticipation.new(enrollment: enrollment).individual_ratings_editable?
    end

    should "false when concluded" do
      enrollment = create(:assessment_cycle_enrollment, :concluded, tenant: @tenant, cycle: @cycle, person_id: @person_id)
      assert_not AssessmentCycleParticipation.new(enrollment: enrollment).individual_ratings_editable?
    end
  end

  context "delegation" do
    setup do
      @enrollment = create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)
      @progress = create(:assessment_cycle_progress, :aligning,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)
      @participation = AssessmentCycleParticipation.new(enrollment: @enrollment, progress: @progress)
    end

    should "delegates enrolled_at / withdrawal_reason to enrollment" do
      assert_equal @enrollment.enrolled_at, @participation.enrolled_at
      assert_nil @participation.withdrawal_reason
    end

    should "delegates alignment_started_at / aligned_at to progress (nil-safe)" do
      assert_equal @progress.alignment_started_at, @participation.alignment_started_at
      assert_nil @participation.aligned_at
    end

    should "progress delegations return nil when progress is absent" do
      enrollment_only = AssessmentCycleParticipation.new(enrollment: @enrollment)
      assert_nil enrollment_only.started_at
      assert_nil enrollment_only.alignment_started_at
      assert_nil enrollment_only.aligned_at
    end
  end

  context ".find_by(cycle_id:, person_id:)" do
    should "returns nil when no enrollment exists" do
      assert_nil AssessmentCycleParticipation.find_by(
        cycle_id: @cycle.cycle_id, person_id: @person_id
      )
    end

    should "wraps enrollment + progress together" do
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)
      create(:assessment_cycle_progress, :started,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)

      result = AssessmentCycleParticipation.find_by(
        cycle_id: @cycle.cycle_id, person_id: @person_id
      )
      assert_not_nil result
      assert_equal "started", result.status
    end

    should "wraps enrollment without progress when only enrollment exists" do
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: @cycle, person_id: @person_id)

      result = AssessmentCycleParticipation.find_by(
        cycle_id: @cycle.cycle_id, person_id: @person_id
      )
      assert_not_nil result
      assert_nil result.progress
      assert_equal "enrolled", result.status
    end
  end

  context ".for_enrollments" do
    should "preloads progress for given enrollments in one extra query" do
      enrollments = 3.times.map do |i|
        e = create(:assessment_cycle_enrollment,
          tenant: @tenant, cycle: @cycle, person_id: SecureRandom.uuid_v7)
        create(:assessment_cycle_progress, :started,
          tenant: @tenant, cycle: @cycle, person_id: e.person_id) if i.even?
        e
      end

      results = AssessmentCycleParticipation.for_enrollments(enrollments)
      assert_equal 3, results.size
      with_progress = results.count { |r| r.progress.present? }
      assert_equal 2, with_progress
    end
  end
end
