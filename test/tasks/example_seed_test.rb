# frozen_string_literal: true

require "test_helper"
require "rake"
require_relative "../../lib/tasks/example_seed"

class ExampleSeedTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @admin = create(:user, global_admin: true)
  end

  should "seed the demo tenant and converge on a second run" do
    io = StringIO.new
    tenant = ExampleSeed.new(admin_user: @admin, io: io).call

    counts = ActsAsTenant.with_tenant(tenant) { snapshot }
    assert_equal 21, counts[:people]
    assert_equal 20, counts[:assignments], "everyone but the VP is assigned"
    assert_equal 20, counts[:enrollments]
    assert_equal 0, counts[:snapshotless_enrollments], "every enrollment carries its role/level snapshot"
    assert_operator counts[:ratings], :>, 0
    assert_equal 2, counts[:aligned], "two assessments are fully aligned"
    assert_operator counts[:evidence], :>=, 7
    assert_equal 1, counts[:withdrawn_evidence]
    assert_equal 4, counts[:pending_suggestions]
    assert counts[:draft_in_progress], "a v2 draft stays open for the explorer to show"
    assert_equal 1, counts[:pending_requests]
    assert Tenant.exists?(slug: ExampleSeed::SECOND_TENANT[:slug]), "the switcher has a second workspace"
    assert_equal "Ladder", tenant.product_name, "the demo tenant brands its own instance"

    rerun = ExampleSeed.new(admin_user: @admin, io: StringIO.new).call
    assert_equal counts, ActsAsTenant.with_tenant(rerun) { snapshot }, "a re-run converges"
  end

  should "leave the demo cycle alone once the calibration seed has closed it" do
    tenant = ExampleSeed.new(admin_user: @admin, io: StringIO.new).call
    ActsAsTenant.with_tenant(tenant) do
      cycle = AssessmentCycle.find_by!(name: ExampleSeed::CYCLE_NAME)
      AssessmentCycles::CommandHandler.new.close_cycle(cycle.cycle_id, closed_by: Person.find_by!(manager_id: nil).id)
      # A person added to the seed since: the re-run sees them unenrolled.
      AssessmentCycleEnrollment.where(cycle_id: cycle.cycle_id).first.delete
    end

    io = StringIO.new
    ExampleSeed.new(admin_user: @admin, io: io).call
    assert_match "is closed — leaving it alone", io.string
  end

  private

  def snapshot
    framework = FrameworkState::Framework.first
    {
      people: Person.count,
      assignments: PersonFrameworkAssignment.count,
      enrollments: AssessmentCycleEnrollment.count,
      snapshotless_enrollments: AssessmentCycleEnrollment.where(role_id: nil).count,
      ratings: AssessmentLevelRating.across_all_roles.count,
      aligned: AssessmentCycleProgress.where(status: "aligned").count,
      evidence: EvidenceItem.count,
      withdrawn_evidence: EvidenceItem.where(link_status: "withdrawn").count,
      pending_suggestions: FrameworkState::SuggestedEdit.where(status: "pending").count,
      draft_in_progress: framework.reload.draft_in_progress,
      pending_requests: EvidenceRequest.where(status: "pending").count
    }
  end
end
