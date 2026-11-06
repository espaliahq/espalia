# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

# CurrentAssessment's per-role alignment rows and the `started` rule
# (ADR-22). Events are appended to the real stream and projected directly,
# so a reset! + replay can prove the rows rebuild — including from event
# shapes written before per-role alignment existed.
class PersonDevelopment::Projections::CurrentAssessmentRoleAlignmentTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  setup do
    @tenant = create(:tenant)
    @projection = PersonDevelopment::Projections::CurrentAssessment.new
    @framework_id = SecureRandom.uuid_v7
    @cycle_id = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(@tenant) do
      create(:framework_state, framework_id: @framework_id)
      family = create(:framework_role_family, framework_id: @framework_id)
      @engineer = create(:framework_role, role_family_id: family.role_family_id, code: "E")
      @pm = create(:framework_role, role_family_id: family.role_family_id, code: "PM")
      @e3 = create(:framework_level, role_id: @engineer.role_id, ordinal: 3)
      category = create(:framework_capability_category, framework_id: @framework_id)
      @shared = bound_capability(category, [ @engineer, @pm ])
      @pm_only = bound_capability(category, [ @pm ])

      @manager = create(:person, tenant: @tenant)
      @person_id = create(:person, tenant: @tenant).id
      cycle = create(:assessment_cycle, tenant: @tenant, cycle_id: @cycle_id, framework_id: @framework_id)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: cycle, person_id: @person_id,
             role_id: @engineer.role_id, level_id: @e3.level_id, level_ordinal: 3)
    end

    append_and_project(PersonDevelopment::Events::PersonAssignedToFramework,
      person_id: @person_id, framework_id: @framework_id, role_id: @engineer.role_id, level_id: @e3.level_id)
    append_and_project(PersonDevelopment::Events::JoinedAssessmentCycle, cycle_id: @cycle_id, framework_version: 1)
  end

  def bound_capability(category, roles)
    capability = create(:framework_capability, category_id: category.category_id)
    roles.each { |role| create(:framework_capability_role_binding, capability_id: capability.capability_id, role_id: role.role_id) }
    create(:framework_behavioural_expectation, capability_id: capability.capability_id, level_ordinal: 3)
    capability
  end

  def progress
    ActsAsTenant.with_tenant(@tenant) { AssessmentCycleProgress.find_by(cycle_id: @cycle_id, person_id: @person_id) }
  end

  def role_alignment(role)
    ActsAsTenant.with_tenant(@tenant) do
      AssessmentCycleRoleAlignment.find_by(cycle_id: @cycle_id, person_id: @person_id, role_id: role.role_id)
    end
  end

  def self_rate(capability, source: "human", via_role_id: nil)
    append_and_project(PersonDevelopment::Events::SelfRated, cycle_id: @cycle_id,
      capability_stable_id: capability.stable_id, level_ordinal: 3, frequency: "some", source: source,
      via_role_id: via_role_id)
  end

  def start(role, cells: [])
    append_and_project(PersonDevelopment::Events::AlignmentStarted, cycle_id: @cycle_id,
      started_by_id: @manager.id, role_id: role.role_id, level_ordinal: 3, cell_keys: cells)
  end

  context "the started rule" do
    should "leave a participation unstarted by a lens rating on a cell only another role reads" do
      self_rate(@pm_only, via_role_id: @pm.role_id)

      assert_nil progress.started_at
      assert_equal "in_progress", progress.status
    end

    should "start it on a lens rating the home role also reads" do
      self_rate(@shared, via_role_id: @pm.role_id)

      assert_equal "started", progress.status
    end

    # A rating made on the record counts whatever the framework says today —
    # a rebuild must not un-start a participation whose capability was
    # unbound since.
    should "start it on any rating made on the record" do
      self_rate(@pm_only)

      assert_equal "started", progress.status
    end
  end

  context "alignment against a lens role" do
    setup { start(@pm, cells: [ [ @pm_only.stable_id, 3 ] ]) }

    should "write the role's row and leave the home lifecycle alone" do
      row = role_alignment(@pm)
      assert_equal "aligning", row.status
      assert_not row.home
      assert_not row.whole_assessment
      assert_equal 3, row.level_ordinal
      assert_equal @manager.id, row.alignment_started_by_id
      assert_nil progress.alignment_started_at
      assert_not_equal "aligning", progress.status
    end

    should "complete and re-open on the role's row only" do
      append_and_project(PersonDevelopment::Events::FullAlignmentCompleted, cycle_id: @cycle_id,
        completed_by_id: @manager.id, framework_version: 1, role_id: @pm.role_id)
      assert_equal "aligned", role_alignment(@pm).status
      assert_not_equal "aligned", progress.status

      append_and_project(PersonDevelopment::Events::AlignmentReopened, cycle_id: @cycle_id,
        reopened_by_id: @manager.id, role_id: @pm.role_id)
      row = role_alignment(@pm)
      assert_equal "aligning", row.status
      assert_nil row.aligned_at
      assert_equal @manager.id, row.reopened_by_id
    end
  end

  context "alignment against the home role" do
    should "write the home row beside the progress row" do
      start(@engineer, cells: [ [ @shared.stable_id, 3 ] ])

      row = role_alignment(@engineer)
      assert row.home
      assert_equal "aligning", progress.status
    end
  end

  context "history without a role" do
    setup do
      # Every alignment event before per-role alignment had this shape.
      append_and_project(PersonDevelopment::Events::AlignmentStarted, cycle_id: @cycle_id, started_by_id: @manager.id)
      append_and_project(PersonDevelopment::Events::FullAlignmentCompleted, cycle_id: @cycle_id,
        completed_by_id: @manager.id, framework_version: 1)
    end

    should "be the home role's alignment over the whole assessment" do
      row = role_alignment(@engineer)
      assert row.home
      assert row.whole_assessment
      assert_equal 3, row.level_ordinal
      assert_equal "aligned", row.status
      assert_equal "aligned", progress.status
    end
  end

  # Home follows a transfer or promotion until alignment starts, then the
  # conversation pins it (https://github.com/mr-yum/growth-os/issues/687).
  context "history without a role after a transfer before alignment" do
    setup do
      transfer_to_pm
      append_and_project(PersonDevelopment::Events::AlignmentStarted, cycle_id: @cycle_id, started_by_id: @manager.id)
      append_and_project(PersonDevelopment::Events::FullAlignmentCompleted, cycle_id: @cycle_id,
        completed_by_id: @manager.id, framework_version: 1)
    end

    should "be the new role's, at its level, through a rebuild" do
      rebuild

      row = role_alignment(@pm)
      assert row.home
      assert_equal 4, row.level_ordinal
      assert_equal "aligned", row.status
      assert_nil role_alignment(@engineer)
      assert_equal "aligned", progress.status
    end

    should "agree with the lifecycle timeline" do
      milestones = ActsAsTenant.with_tenant(@tenant) do
        assignment = PersonFrameworkAssignment.find_by!(person_id: @person_id, framework_id: @framework_id)
        Assessments::LifecycleTimeline.new(assignment: assignment)
          .call(cycle_id: @cycle_id, kinds: %w[alignment_started alignment_completed])
      end

      assert_equal 2, milestones.size
      assert(milestones.all? { |m| m.role_id == @pm.role_id && m.home })
    end
  end

  should "follow a promotion made before alignment starts" do
    e4 = ActsAsTenant.with_tenant(@tenant) { create(:framework_level, role_id: @engineer.role_id, ordinal: 4) }
    append_and_project(PersonDevelopment::Events::PersonLevelChanged,
      previous_level_id: @e3.level_id, new_level_id: e4.level_id, reason: "promotion")
    append_and_project(PersonDevelopment::Events::AlignmentStarted, cycle_id: @cycle_id, started_by_id: @manager.id)

    row = role_alignment(@engineer)
    assert row.home
    assert_equal 4, row.level_ordinal
  end

  # Before the fix a rebuild read the enrollment snapshot as it ended, so a
  # transfer judged every earlier event against the new role. The snapshot is
  # moved here as the sync handler moved it before alignment pinned it.
  context "a transfer after alignment starts" do
    setup do
      self_rate(@pm_only, via_role_id: @pm.role_id)
      append_and_project(PersonDevelopment::Events::AlignmentStarted, cycle_id: @cycle_id, started_by_id: @manager.id)
      transfer_to_pm(move_snapshot: true)
      append_and_project(PersonDevelopment::Events::FullAlignmentCompleted, cycle_id: @cycle_id,
        completed_by_id: @manager.id, framework_version: 1)
    end

    should "keep the alignment, the progress row and started on the role it began on" do
      assert role_alignment(@engineer).home
      assert_equal "aligned", role_alignment(@engineer).status
      assert_nil role_alignment(@pm)
      assert_equal @engineer.role_id, progress.home_role_id
      assert_equal "aligned", progress.status
    end

    should "rebuild every row identically" do
      assert_rebuilds_identically
    end
  end

  should "count completion against the pinned home after a transfer" do
    self_rate(@shared)
    assert progress.self_completed_at

    start(@engineer, cells: [ [ @shared.stable_id, 3 ] ])
    transfer_to_pm(move_snapshot: true)
    self_rate(@pm_only, via_role_id: @pm.role_id)

    assert progress.self_completed_at
  end

  should "rebuild a lens rating made before a transfer as unstarted" do
    self_rate(@pm_only, via_role_id: @pm.role_id)
    transfer_to_pm(move_snapshot: true)

    assert_rebuilds_identically
    assert_nil progress.started_at
  end

  should "clear a participation's role rows when the person re-joins the cycle" do
    start(@pm, cells: [])
    append_and_project(PersonDevelopment::Events::JoinedAssessmentCycle, cycle_id: @cycle_id, framework_version: 1)

    assert_nil role_alignment(@pm)
  end

  should "rebuild every row identically from old and new event shapes" do
    self_rate(@pm_only, via_role_id: @pm.role_id)
    append_and_project(PersonDevelopment::Events::AlignmentStarted, cycle_id: @cycle_id, started_by_id: @manager.id)
    start(@pm, cells: [ [ @pm_only.stable_id, 3 ] ])
    append_and_project(PersonDevelopment::Events::FullAlignmentCompleted, cycle_id: @cycle_id,
      completed_by_id: @manager.id, framework_version: 1, role_id: @pm.role_id)
    append_and_project(PersonDevelopment::Events::AlignmentReopened, cycle_id: @cycle_id,
      reopened_by_id: @manager.id, role_id: @pm.role_id)

    before = snapshot_read_models(PersonDevelopment::Projections::CurrentAssessment, @tenant)
    assert_equal 2, before[:role_alignments].size

    PersonDevelopment::Projections::CurrentAssessment.reset!(tenant: @tenant)
    ActsAsTenant.with_tenant(@tenant) { assert_equal 0, AssessmentCycleRoleAlignment.count }
    Projections::Replayer.replay(projection_class: PersonDevelopment::Projections::CurrentAssessment, tenant: @tenant)

    assert_equal before, snapshot_read_models(PersonDevelopment::Projections::CurrentAssessment, @tenant)
  end

  private

  def transfer_to_pm(move_snapshot: false)
    pm4 = ActsAsTenant.with_tenant(@tenant) { create(:framework_level, role_id: @pm.role_id, ordinal: 4) }
    append_and_project(PersonDevelopment::Events::PersonRoleChanged, previous_role_id: @engineer.role_id,
      new_role_id: @pm.role_id, previous_level_id: @e3.level_id, new_level_id: pm4.level_id, reason: "transfer")
    return unless move_snapshot

    ActsAsTenant.with_tenant(@tenant) do
      AssessmentCycleEnrollment.find_by!(cycle_id: @cycle_id, person_id: @person_id)
        .update!(role_id: @pm.role_id, level_id: pm4.level_id, level_ordinal: 4)
    end
  end

  def rebuild
    PersonDevelopment::Projections::CurrentAssessment.reset!(tenant: @tenant)
    Projections::Replayer.replay(projection_class: PersonDevelopment::Projections::CurrentAssessment, tenant: @tenant)
  end

  def assert_rebuilds_identically
    before = snapshot_read_models(PersonDevelopment::Projections::CurrentAssessment, @tenant)
    rebuild
    assert_equal before, snapshot_read_models(PersonDevelopment::Projections::CurrentAssessment, @tenant)
  end

  def append_and_project(event_class, **data)
    event = event_class.new(
      data: data,
      metadata: { tenant_id: @tenant.id, person_id: @person_id, framework_id: @framework_id }
    )
    stream = EventStreamNaming.person_development_stream(@person_id, @framework_id, tenant: @tenant)
    Rails.configuration.event_store.append(event, stream_name: stream)
    @projection.call(event)
  end
end
