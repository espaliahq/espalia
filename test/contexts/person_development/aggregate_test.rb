# frozen_string_literal: true

require "test_helper"

class PersonDevelopment::AggregateTest < ActiveSupport::TestCase
  setup do
    @aggregate = PersonDevelopment::Aggregate.new
    @person_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @role_id = SecureRandom.uuid_v7
    @level_id = SecureRandom.uuid_v7
  end

  # ── Assignment ──

  context "#assign_to_framework" do
    should "apply PersonAssignedToFramework event" do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)

      events = @aggregate.unpublished_events.to_a
      assert_equal 1, events.length
      assert_kind_of PersonDevelopment::Events::PersonAssignedToFramework, events.first
      assert_equal @person_id, events.first.data[:person_id]
      assert_equal @framework_id, events.first.data[:framework_id]
      assert_equal @role_id, events.first.data[:role_id]
      assert_equal @level_id, events.first.data[:level_id]
    end

    should "capture assigned_by when provided, nil otherwise" do
      actor = SecureRandom.uuid_v7
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id, assigned_by: actor)
      assert_equal actor, @aggregate.unpublished_events.to_a.last.data[:assigned_by]

      fresh = PersonDevelopment::Aggregate.new
      fresh.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      assert_nil fresh.unpublished_events.to_a.last.data[:assigned_by]
    end

    should "raise if already assigned" do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)

      err = assert_raises(RuntimeError) do
        @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      end
      assert_match /already assigned/, err.message
    end
  end

  # ── Framework Version Migration ──

  context "#migrate_framework_version" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @mappings = [
        { from_stable_id: SecureRandom.uuid_v7, to_stable_id: SecureRandom.uuid_v7,
          mapping_type: "same", requires_reassessment: false,
          counts: { ratings: 0, evidence: 0, comments: 0 } }
      ]
    end

    should "apply FrameworkVersionMigrated with the mappings payload" do
      @aggregate.migrate_framework_version(@framework_id, 1, 2, @mappings)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::FrameworkVersionMigrated, event
      assert_equal 1, event.data[:old_version]
      assert_equal 2, event.data[:new_version]
      assert_equal @mappings, event.data[:mappings]
    end

    should "refuse to migrate once the current cycle's alignment is completed" do
      cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(cycle_id, 1)
      @aggregate.start_alignment(cycle_id, started_by_id: SecureRandom.uuid_v7)
      @aggregate.complete_alignment(cycle_id, completed_by_id: SecureRandom.uuid_v7)

      err = assert_raises(RuntimeError) do
        @aggregate.migrate_framework_version(@framework_id, 1, 2, @mappings)
      end
      assert_match(/completed assessment cycle/, err.message)
    end

    should "raise when not assigned to the framework" do
      err = assert_raises(RuntimeError) do
        @aggregate.migrate_framework_version(SecureRandom.uuid_v7, 1, 2, @mappings)
      end
      assert_match /does not match assignment/, err.message
    end

    should "no-op when stream has already been migrated to the same version" do
      @aggregate.migrate_framework_version(@framework_id, 1, 2, @mappings)
      events_before = @aggregate.unpublished_events.to_a.size

      @aggregate.migrate_framework_version(@framework_id, 1, 2, @mappings)
      events_after = @aggregate.unpublished_events.to_a.size

      assert_equal events_before, events_after, "should not emit a second event for the same version"
    end

    should "no-op when stream has already been migrated past the requested version" do
      @aggregate.migrate_framework_version(@framework_id, 1, 3, @mappings)
      events_before = @aggregate.unpublished_events.to_a.size

      @aggregate.migrate_framework_version(@framework_id, 2, 3, @mappings)
      events_after = @aggregate.unpublished_events.to_a.size

      assert_equal events_before, events_after
    end
  end

  # ── Role Change ──

  context "#change_role" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @new_role_id = SecureRandom.uuid_v7
      @new_level_id = SecureRandom.uuid_v7
    end

    should "apply PersonRoleChanged event with previous and new ids" do
      @aggregate.change_role(@new_role_id, @new_level_id, reason: "hris_sync")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::PersonRoleChanged, event
      assert_equal @role_id, event.data[:previous_role_id]
      assert_equal @new_role_id, event.data[:new_role_id]
      assert_equal @level_id, event.data[:previous_level_id]
      assert_equal @new_level_id, event.data[:new_level_id]
      assert_equal "hris_sync", event.data[:reason]
    end

    should "capture changed_by when provided" do
      actor = SecureRandom.uuid_v7
      @aggregate.change_role(@new_role_id, @new_level_id, reason: "manual", changed_by: actor)
      assert_equal actor, @aggregate.unpublished_events.to_a.last.data[:changed_by]
    end

    should "raise if not assigned" do
      aggregate = PersonDevelopment::Aggregate.new
      err = assert_raises(RuntimeError) do
        aggregate.change_role(@new_role_id, @new_level_id)
      end
      assert_match /not yet assigned/, err.message
    end

    should "raise if role is unchanged" do
      err = assert_raises(RuntimeError) do
        @aggregate.change_role(@role_id, @new_level_id)
      end
      assert_match /unchanged/, err.message
    end
  end

  # ── Level Change ──

  context "#change_level" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @new_level_id = SecureRandom.uuid_v7
    end

    should "apply PersonLevelChanged event" do
      @aggregate.change_level(@new_level_id, reason: "hris_sync")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::PersonLevelChanged, event
      assert_equal @level_id, event.data[:previous_level_id]
      assert_equal @new_level_id, event.data[:new_level_id]
      assert_equal "hris_sync", event.data[:reason]
    end

    should "capture changed_by when provided" do
      actor = SecureRandom.uuid_v7
      @aggregate.change_level(@new_level_id, reason: "manual", changed_by: actor)
      assert_equal actor, @aggregate.unpublished_events.to_a.last.data[:changed_by]
    end

    should "raise if not assigned" do
      aggregate = PersonDevelopment::Aggregate.new
      err = assert_raises(RuntimeError) do
        aggregate.change_level(@new_level_id)
      end
      assert_match /not yet assigned/, err.message
    end

    should "raise if level is unchanged" do
      err = assert_raises(RuntimeError) do
        @aggregate.change_level(@level_id)
      end
      assert_match /unchanged/, err.message
    end
  end

  context "#unassign_from_framework" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
    end

    should "apply PersonUnassignedFromFramework with the previous role/level" do
      @aggregate.unassign_from_framework(reason: "data_correction")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::PersonUnassignedFromFramework, event
      assert_equal @role_id, event.data[:previous_role_id]
      assert_equal @level_id, event.data[:previous_level_id]
      assert_equal "data_correction", event.data[:reason]
    end

    should "default the reason to manual and capture unassigned_by when provided" do
      actor = SecureRandom.uuid_v7
      @aggregate.unassign_from_framework(unassigned_by: actor)

      event = @aggregate.unpublished_events.to_a.last
      assert_equal "manual", event.data[:reason]
      assert_equal actor, event.data[:unassigned_by]
    end

    should "clear assignment so the person can be re-assigned afterward" do
      @aggregate.unassign_from_framework

      # Re-assigning would raise "already assigned" if @assigned were still set.
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      assert_kind_of PersonDevelopment::Events::PersonAssignedToFramework,
                     @aggregate.unpublished_events.to_a.last
    end

    should "raise if not assigned" do
      aggregate = PersonDevelopment::Aggregate.new
      err = assert_raises(RuntimeError) do
        aggregate.unassign_from_framework
      end
      assert_match /not yet assigned/, err.message
    end

    should "raise while still enrolled in a cycle" do
      @aggregate.join_cycle(SecureRandom.uuid_v7, 1)

      err = assert_raises(RuntimeError) do
        @aggregate.unassign_from_framework
      end
      assert_match /enrolled in a cycle/, err.message
    end

    should "allow unassign once the person has left the cycle" do
      cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(cycle_id, 1)
      @aggregate.leave_cycle(cycle_id, "unenrolled")

      @aggregate.unassign_from_framework
      assert_kind_of PersonDevelopment::Events::PersonUnassignedFromFramework,
                     @aggregate.unpublished_events.to_a.last
    end
  end

  # ── Assessment Cycle Membership ──

  context "#join_cycle" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
    end

    should "apply JoinedAssessmentCycle event" do
      cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(cycle_id, 1)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::JoinedAssessmentCycle, event
      assert_equal cycle_id, event.data[:cycle_id]
      assert_equal 1, event.data[:framework_version]
    end

    should "raise if not assigned" do
      aggregate = PersonDevelopment::Aggregate.new
      err = assert_raises(RuntimeError) do
        aggregate.join_cycle(SecureRandom.uuid_v7, 1)
      end
      assert_match /not yet assigned/, err.message
    end

    should "raise if already in a cycle" do
      @aggregate.join_cycle(SecureRandom.uuid_v7, 1)

      err = assert_raises(RuntimeError) do
        @aggregate.join_cycle(SecureRandom.uuid_v7, 1)
      end
      assert_match /Already in a cycle/, err.message
    end
  end

  context "#leave_cycle" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(@cycle_id, 1)
    end

    should "apply LeftAssessmentCycle event" do
      @aggregate.leave_cycle(@cycle_id, "manual")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::LeftAssessmentCycle, event
      assert_equal @cycle_id, event.data[:cycle_id]
      assert_equal "manual", event.data[:reason]
    end

    should "allow rejoining after leaving" do
      @aggregate.leave_cycle(@cycle_id, "manual")
      new_cycle = SecureRandom.uuid_v7
      @aggregate.join_cycle(new_cycle, 2)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::JoinedAssessmentCycle, event
      assert_equal new_cycle, event.data[:cycle_id]
    end

    should "raise if not in a cycle" do
      @aggregate.leave_cycle(@cycle_id, "manual")

      err = assert_raises(RuntimeError) do
        @aggregate.leave_cycle(@cycle_id, "manual")
      end
      assert_match /Not currently in an assessment cycle/, err.message
    end

    should "raise if cycle_id does not match" do
      err = assert_raises(RuntimeError) do
        @aggregate.leave_cycle(SecureRandom.uuid_v7, "manual")
      end
      assert_match /does not match/, err.message
    end

    should "reject the legacy cycle_closed reason" do
      err = assert_raises(RuntimeError) do
        @aggregate.leave_cycle(@cycle_id, "cycle_closed")
      end
      assert_match /Use conclude_cycle/, err.message
    end
  end

  context "#conclude_cycle" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(@cycle_id, 1)
    end

    should "apply AssessmentCycleConcluded event" do
      @aggregate.conclude_cycle(@cycle_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::AssessmentCycleConcluded, event
      assert_equal @cycle_id, event.data[:cycle_id]
    end

    should "allow joining a new cycle after conclusion" do
      @aggregate.conclude_cycle(@cycle_id)
      new_cycle = SecureRandom.uuid_v7
      @aggregate.join_cycle(new_cycle, 2)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::JoinedAssessmentCycle, event
      assert_equal new_cycle, event.data[:cycle_id]
    end

    should "raise if not in a cycle" do
      @aggregate.conclude_cycle(@cycle_id)

      err = assert_raises(RuntimeError) do
        @aggregate.conclude_cycle(@cycle_id)
      end
      assert_match /Not currently in an assessment cycle/, err.message
    end

    should "raise if cycle_id does not match" do
      err = assert_raises(RuntimeError) do
        @aggregate.conclude_cycle(SecureRandom.uuid_v7)
      end
      assert_match /does not match/, err.message
    end
  end

  # ── Self-Rating ──

  context "#rate_self" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(@cycle_id, 1)
    end

    should "apply SelfRated event with cycle_id, level_ordinal and frequency" do
      cap_sid = SecureRandom.uuid_v7
      @aggregate.rate_self(cap_sid, level_ordinal: 3, frequency: "consistent",
        cycle_id: @cycle_id, comment: "Strong")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::SelfRated, event
      assert_equal cap_sid, event.data[:capability_stable_id]
      assert_equal 3, event.data[:level_ordinal]
      assert_equal "consistent", event.data[:frequency]
      assert_equal @cycle_id, event.data[:cycle_id]
      assert_equal "Strong", event.data[:comment]
    end

    should "accept 'none' as a valid frequency" do
      cap_sid = SecureRandom.uuid_v7
      @aggregate.rate_self(cap_sid, level_ordinal: 2, frequency: "none", cycle_id: @cycle_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::SelfRated, event
      assert_equal "none", event.data[:frequency]
    end

    should "raise for invalid frequency" do
      err = assert_raises(RuntimeError) do
        @aggregate.rate_self(SecureRandom.uuid_v7, level_ordinal: 1, frequency: "sometimes",
          cycle_id: @cycle_id)
      end
      assert_match /Invalid frequency/, err.message
    end

    should "raise if not in a cycle" do
      aggregate = PersonDevelopment::Aggregate.new
      aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)

      err = assert_raises(RuntimeError) do
        aggregate.rate_self(SecureRandom.uuid_v7, level_ordinal: 1, frequency: "some",
          cycle_id: SecureRandom.uuid_v7)
      end
      assert_match /Not currently in an assessment cycle/, err.message
    end

    should "raise if cycle_id does not match current" do
      err = assert_raises(RuntimeError) do
        @aggregate.rate_self(SecureRandom.uuid_v7, level_ordinal: 1, frequency: "some",
          cycle_id: SecureRandom.uuid_v7)
      end
      assert_match /does not match/, err.message
    end
  end

  context "#revise_self_rating" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(@cycle_id, 1)
      @cap_sid = SecureRandom.uuid_v7
      @aggregate.rate_self(@cap_sid, level_ordinal: 3, frequency: "some", cycle_id: @cycle_id)
    end

    should "apply SelfRatingRevised event" do
      @aggregate.revise_self_rating(@cap_sid, level_ordinal: 3, frequency: "consistent",
        rationale: "Reconsidered", cycle_id: @cycle_id, comment: "Updated")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::SelfRatingRevised, event
      assert_equal @cap_sid, event.data[:capability_stable_id]
      assert_equal 3, event.data[:level_ordinal]
      assert_equal "consistent", event.data[:frequency]
      assert_equal @cycle_id, event.data[:cycle_id]
      assert_equal "Reconsidered", event.data[:rationale]
      assert_equal "Updated", event.data[:comment]
    end

    should "raise if no prior self-rating for capability at that level" do
      err = assert_raises(RuntimeError) do
        @aggregate.revise_self_rating(@cap_sid, level_ordinal: 4, frequency: "some",
          rationale: "test", cycle_id: @cycle_id)
      end
      assert_match /No self-rating exists/, err.message
    end
  end

  # ── Manager Rating ──

  context "#rate_as_manager" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(@cycle_id, 1)
    end

    should "apply ManagerRated event with cycle_id" do
      cap_sid = SecureRandom.uuid_v7
      @aggregate.rate_as_manager(cap_sid, level_ordinal: 2, frequency: "occasional",
        cycle_id: @cycle_id, comment: "Needs work")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::ManagerRated, event
      assert_equal cap_sid, event.data[:capability_stable_id]
      assert_equal 2, event.data[:level_ordinal]
      assert_equal "occasional", event.data[:frequency]
      assert_equal @cycle_id, event.data[:cycle_id]
      assert_equal "Needs work", event.data[:comment]
    end

    should "capture rated_by_id on the ManagerRated event" do
      rater_id = SecureRandom.uuid_v7
      @aggregate.rate_as_manager(SecureRandom.uuid_v7, level_ordinal: 2, frequency: "consistent",
        cycle_id: @cycle_id, rated_by_id: rater_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_equal rater_id, event.data[:rated_by_id]
    end

    should "default rated_by_id to nil (e.g. seeded carry-forwards)" do
      @aggregate.rate_as_manager(SecureRandom.uuid_v7, level_ordinal: 2, frequency: "consistent",
        cycle_id: @cycle_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_nil event.data[:rated_by_id]
    end

    should "raise for invalid frequency" do
      err = assert_raises(RuntimeError) do
        @aggregate.rate_as_manager(SecureRandom.uuid_v7, level_ordinal: 1, frequency: "never",
          cycle_id: @cycle_id)
      end
      assert_match /Invalid frequency/, err.message
    end
  end

  context "#revise_manager_rating" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(@cycle_id, 1)
      @cap_sid = SecureRandom.uuid_v7
      @aggregate.rate_as_manager(@cap_sid, level_ordinal: 3, frequency: "some", cycle_id: @cycle_id)
    end

    should "apply ManagerRatingRevised event" do
      @aggregate.revise_manager_rating(@cap_sid, level_ordinal: 3, frequency: "consistent",
        rationale: "Reconsidered", cycle_id: @cycle_id, comment: "Updated")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::ManagerRatingRevised, event
      assert_equal @cap_sid, event.data[:capability_stable_id]
      assert_equal 3, event.data[:level_ordinal]
      assert_equal "consistent", event.data[:frequency]
      assert_equal @cycle_id, event.data[:cycle_id]
      assert_equal "Reconsidered", event.data[:rationale]
      assert_equal "Updated", event.data[:comment]
    end

    should "capture rated_by_id on the ManagerRatingRevised event" do
      rater_id = SecureRandom.uuid_v7
      @aggregate.revise_manager_rating(@cap_sid, level_ordinal: 3, frequency: "consistent",
        rationale: "Reconsidered", cycle_id: @cycle_id, rated_by_id: rater_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_equal rater_id, event.data[:rated_by_id]
    end

    should "raise if no prior manager rating for capability at that level" do
      err = assert_raises(RuntimeError) do
        @aggregate.revise_manager_rating(@cap_sid, level_ordinal: 4, frequency: "some",
          rationale: "test", cycle_id: @cycle_id)
      end
      assert_match /No manager rating exists/, err.message
    end

    should "raise for invalid frequency" do
      err = assert_raises(RuntimeError) do
        @aggregate.revise_manager_rating(@cap_sid, level_ordinal: 3, frequency: "always",
          rationale: "test", cycle_id: @cycle_id)
      end
      assert_match /Invalid frequency/, err.message
    end
  end

  context "#clear_manager_rating" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(@cycle_id, 1)
      @cap_sid = SecureRandom.uuid_v7
      @aggregate.rate_as_manager(@cap_sid, level_ordinal: 3, frequency: "some", cycle_id: @cycle_id)
    end

    should "apply ManagerRatingCleared event" do
      @aggregate.clear_manager_rating(@cap_sid, level_ordinal: 3, cycle_id: @cycle_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::ManagerRatingCleared, event
      assert_equal @cap_sid, event.data[:capability_stable_id]
      assert_equal 3, event.data[:level_ordinal]
      assert_equal @cycle_id, event.data[:cycle_id]
    end

    should "capture rated_by_id on the ManagerRatingCleared event" do
      rater_id = SecureRandom.uuid_v7
      @aggregate.clear_manager_rating(@cap_sid, level_ordinal: 3, cycle_id: @cycle_id, rated_by_id: rater_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_equal rater_id, event.data[:rated_by_id]
    end

    should "raise if no prior manager rating for capability at that level" do
      err = assert_raises(RuntimeError) do
        @aggregate.clear_manager_rating(@cap_sid, level_ordinal: 4, cycle_id: @cycle_id)
      end
      assert_match /No manager rating exists/, err.message
    end
  end

  # ── Alignment ──

  context "#align_assessment" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(@cycle_id, 1)
      @aggregate.start_alignment(@cycle_id, started_by_id: SecureRandom.uuid_v7)
    end

    should "apply AssessmentAligned event with cycle_id" do
      cap_sid = SecureRandom.uuid_v7
      @aggregate.align_assessment(cap_sid, level_ordinal: 3, aligned_frequency: "consistent",
        cycle_id: @cycle_id, comment: "We agree")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::AssessmentAligned, event
      assert_equal cap_sid, event.data[:capability_stable_id]
      assert_equal 3, event.data[:level_ordinal]
      assert_equal "consistent", event.data[:aligned_frequency]
      assert_equal @cycle_id, event.data[:cycle_id]
      assert_equal "We agree", event.data[:comment]
    end

    should "capture aligned_by_id on the AssessmentAligned event" do
      actor = SecureRandom.uuid_v7
      @aggregate.align_assessment(SecureRandom.uuid_v7, level_ordinal: 3, aligned_frequency: "consistent",
        cycle_id: @cycle_id, aligned_by_id: actor)
      assert_equal actor, @aggregate.unpublished_events.to_a.last.data[:aligned_by_id]
    end

    should "raise for invalid frequency" do
      err = assert_raises(RuntimeError) do
        @aggregate.align_assessment(SecureRandom.uuid_v7, level_ordinal: 1,
          aligned_frequency: "always", cycle_id: @cycle_id)
      end
      assert_match /Invalid/, err.message
    end

    should "raise if not in a cycle" do
      aggregate = PersonDevelopment::Aggregate.new
      aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)

      err = assert_raises(RuntimeError) do
        aggregate.align_assessment(SecureRandom.uuid_v7, level_ordinal: 1,
          aligned_frequency: "some", cycle_id: SecureRandom.uuid_v7)
      end
      assert_match /Not currently in an assessment cycle/, err.message
    end

    should "raise if alignment has not been started" do
      aggregate = PersonDevelopment::Aggregate.new
      aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      cycle_id = SecureRandom.uuid_v7
      aggregate.join_cycle(cycle_id, 1)

      err = assert_raises(RuntimeError) do
        aggregate.align_assessment(SecureRandom.uuid_v7, level_ordinal: 1,
          aligned_frequency: "some", cycle_id: cycle_id)
      end
      assert_match /Alignment has not been started/, err.message
    end
  end

  context "#clear_alignment_rating" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(@cycle_id, 1)
      @aggregate.start_alignment(@cycle_id, started_by_id: SecureRandom.uuid_v7)
      @cap_sid = SecureRandom.uuid_v7
      @aggregate.align_assessment(@cap_sid, level_ordinal: 3, aligned_frequency: "consistent",
        cycle_id: @cycle_id)
    end

    should "apply AlignmentCleared event with cycle_id" do
      @aggregate.clear_alignment_rating(@cap_sid, level_ordinal: 3, cycle_id: @cycle_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::AlignmentCleared, event
      assert_equal @cap_sid, event.data[:capability_stable_id]
      assert_equal 3, event.data[:level_ordinal]
      assert_equal @cycle_id, event.data[:cycle_id]
    end

    should "capture cleared_by_id on the AlignmentCleared event" do
      actor = SecureRandom.uuid_v7
      @aggregate.clear_alignment_rating(@cap_sid, level_ordinal: 3, cycle_id: @cycle_id, cleared_by_id: actor)
      assert_equal actor, @aggregate.unpublished_events.to_a.last.data[:cleared_by_id]
    end

    should "raise if no prior alignment exists for the cell" do
      err = assert_raises(RuntimeError) do
        @aggregate.clear_alignment_rating(@cap_sid, level_ordinal: 4, cycle_id: @cycle_id)
      end
      assert_match /No alignment exists/, err.message
    end

    should "raise if alignment has not been started" do
      aggregate = PersonDevelopment::Aggregate.new
      aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      cycle_id = SecureRandom.uuid_v7
      aggregate.join_cycle(cycle_id, 1)

      err = assert_raises(RuntimeError) do
        aggregate.clear_alignment_rating(SecureRandom.uuid_v7, level_ordinal: 1, cycle_id: cycle_id)
      end
      assert_match /Alignment has not been started/, err.message
    end

    should "raise if alignment has been completed (frozen)" do
      @aggregate.complete_alignment(@cycle_id, completed_by_id: SecureRandom.uuid_v7)

      err = assert_raises(RuntimeError) do
        @aggregate.clear_alignment_rating(@cap_sid, level_ordinal: 3, cycle_id: @cycle_id)
      end
      assert_match /Alignment has been completed/, err.message
    end

    should "not let stale aligned state from a prior cycle leak into a new cycle's clear guard" do
      # Complete cycle A's alignment, then conclude the cycle.
      @aggregate.complete_alignment(@cycle_id, completed_by_id: SecureRandom.uuid_v7)
      @aggregate.conclude_cycle(@cycle_id)

      # Join cycle B and start its alignment. The aggregate's
      # @aligned_ratings must NOT still carry the cycle-A entry, or a
      # clear in cycle B would succeed against stale state and emit a
      # spurious AlignmentCleared event with cycle_id=B for a cell
      # that was never aligned in B.
      cycle_b = SecureRandom.uuid_v7
      @aggregate.join_cycle(cycle_b, 1)
      @aggregate.start_alignment(cycle_b, started_by_id: SecureRandom.uuid_v7)

      err = assert_raises(RuntimeError) do
        @aggregate.clear_alignment_rating(@cap_sid, level_ordinal: 3, cycle_id: cycle_b)
      end
      assert_match /No alignment exists/, err.message
    end
  end

  context "#start_alignment" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(@cycle_id, 1)
      @started_by_id = SecureRandom.uuid_v7
    end

    should "apply AlignmentStarted event with cycle_id and started_by_id" do
      @aggregate.start_alignment(@cycle_id, started_by_id: @started_by_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::AlignmentStarted, event
      assert_equal @cycle_id, event.data[:cycle_id]
      assert_equal @started_by_id, event.data[:started_by_id]
    end

    should "raise if already started" do
      @aggregate.start_alignment(@cycle_id, started_by_id: @started_by_id)

      err = assert_raises(RuntimeError) do
        @aggregate.start_alignment(@cycle_id, started_by_id: @started_by_id)
      end
      assert_match /already started/, err.message
    end

    should "attribute auto-aligned cells to the person who started alignment" do
      cap_sid = SecureRandom.uuid_v7
      @aggregate.rate_self(cap_sid, level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id)
      @aggregate.rate_as_manager(cap_sid, level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id)

      @aggregate.start_alignment(@cycle_id, started_by_id: @started_by_id)

      aligned = @aggregate.unpublished_events.to_a.select do |e|
        e.is_a?(PersonDevelopment::Events::AssessmentAligned)
      end
      assert_equal 1, aligned.length, "expected the agreed cell to auto-align"
      assert_equal @started_by_id, aligned.first.data[:aligned_by_id]
    end

    should "raise if not in a cycle" do
      aggregate = PersonDevelopment::Aggregate.new
      aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)

      err = assert_raises(RuntimeError) do
        aggregate.start_alignment(SecureRandom.uuid_v7, started_by_id: @started_by_id)
      end
      assert_match /Not currently in an assessment cycle/, err.message
    end

    should "freeze rate_self after starting" do
      @aggregate.start_alignment(@cycle_id, started_by_id: @started_by_id)

      err = assert_raises(RuntimeError) do
        @aggregate.rate_self(SecureRandom.uuid_v7, level_ordinal: 1, frequency: "some",
          cycle_id: @cycle_id)
      end
      assert_match /frozen during alignment/, err.message
    end

    should "freeze rate_as_manager after starting" do
      @aggregate.start_alignment(@cycle_id, started_by_id: @started_by_id)

      err = assert_raises(RuntimeError) do
        @aggregate.rate_as_manager(SecureRandom.uuid_v7, level_ordinal: 1, frequency: "some",
          cycle_id: @cycle_id)
      end
      assert_match /frozen during alignment/, err.message
    end

    should "freeze revise_self_rating and clear_self_rating after starting" do
      cap_sid = SecureRandom.uuid_v7
      @aggregate.rate_self(cap_sid, level_ordinal: 1, frequency: "some", cycle_id: @cycle_id)
      @aggregate.start_alignment(@cycle_id, started_by_id: @started_by_id)

      err = assert_raises(RuntimeError) do
        @aggregate.revise_self_rating(cap_sid, level_ordinal: 1, frequency: "occasional",
          rationale: "x", cycle_id: @cycle_id)
      end
      assert_match /frozen during alignment/, err.message

      err = assert_raises(RuntimeError) do
        @aggregate.clear_self_rating(cap_sid, level_ordinal: 1, cycle_id: @cycle_id)
      end
      assert_match /frozen during alignment/, err.message
    end

    should "reset frozen state when a new cycle is joined" do
      @aggregate.start_alignment(@cycle_id, started_by_id: @started_by_id)
      @aggregate.leave_cycle(@cycle_id, "completed")

      new_cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(new_cycle_id, 2)

      # Should be able to rate again
      assert_nothing_raised do
        @aggregate.rate_self(SecureRandom.uuid_v7, level_ordinal: 1, frequency: "some",
          cycle_id: new_cycle_id)
      end
    end
  end

  context "#record_seed_skip" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @aggregate.join_cycle(SecureRandom.uuid_v7, 1)
    end

    should "apply RatingSeedSkipped event with all audit fields" do
      cap_sid = SecureRandom.uuid_v7
      current_cycle_id = SecureRandom.uuid_v7
      prior_cycle_id = SecureRandom.uuid_v7

      @aggregate.record_seed_skip(cap_sid,
        level_ordinal: 3,
        prior_aligned_frequency: "consistent",
        current_cycle_id: current_cycle_id,
        prior_cycle_id: prior_cycle_id,
        reason: "capability_not_in_current_framework")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::RatingSeedSkipped, event
      assert_equal cap_sid, event.data[:capability_stable_id]
      assert_equal 3, event.data[:level_ordinal]
      assert_equal "consistent", event.data[:prior_aligned_frequency]
      assert_equal current_cycle_id, event.data[:current_cycle_id]
      assert_equal prior_cycle_id, event.data[:prior_cycle_id]
      assert_equal "capability_not_in_current_framework", event.data[:reason]
    end

    should "not mutate aggregate state — alignment can still proceed normally" do
      cap_sid = SecureRandom.uuid_v7
      @aggregate.record_seed_skip(cap_sid, level_ordinal: 1,
        prior_aligned_frequency: "some",
        current_cycle_id: SecureRandom.uuid_v7,
        prior_cycle_id: SecureRandom.uuid_v7,
        reason: "capability_not_in_current_framework")

      # Aggregate should still be in a fresh-cycle state — alignment not started.
      assert_nothing_raised do
        @aggregate.start_alignment(@aggregate.instance_variable_get(:@current_cycle_id),
          started_by_id: SecureRandom.uuid_v7)
      end
    end
  end

  context "#complete_alignment" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(@cycle_id, 1)
      @aggregate.start_alignment(@cycle_id, started_by_id: SecureRandom.uuid_v7)
      @completed_by_id = SecureRandom.uuid_v7
    end

    should "apply FullAlignmentCompleted event" do
      @aggregate.complete_alignment(@cycle_id, completed_by_id: @completed_by_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::FullAlignmentCompleted, event
      assert_equal @cycle_id, event.data[:cycle_id]
      assert_equal @completed_by_id, event.data[:completed_by_id]
    end

    should "capture the join framework_version on completion" do
      @aggregate.complete_alignment(@cycle_id, completed_by_id: @completed_by_id)
      assert_equal 1, @aggregate.unpublished_events.to_a.last.data[:framework_version]
    end

    should "capture the migrated-to framework_version when migrated mid-cycle" do
      mappings = [ { from_stable_id: SecureRandom.uuid_v7, to_stable_id: SecureRandom.uuid_v7,
                     mapping_type: "same", requires_reassessment: false,
                     counts: { ratings: 0, evidence: 0, comments: 0 } } ]
      @aggregate.migrate_framework_version(@framework_id, 1, 2, mappings)
      @aggregate.complete_alignment(@cycle_id, completed_by_id: @completed_by_id)
      assert_equal 2, @aggregate.unpublished_events.to_a.last.data[:framework_version]
    end

    should "raise if alignment has not been started" do
      aggregate = PersonDevelopment::Aggregate.new
      aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      cycle_id = SecureRandom.uuid_v7
      aggregate.join_cycle(cycle_id, 1)

      err = assert_raises(RuntimeError) do
        aggregate.complete_alignment(cycle_id, completed_by_id: @completed_by_id)
      end
      assert_match /Alignment has not been started/, err.message
    end

    should "raise if already completed" do
      @aggregate.complete_alignment(@cycle_id, completed_by_id: @completed_by_id)

      err = assert_raises(RuntimeError) do
        @aggregate.complete_alignment(@cycle_id, completed_by_id: @completed_by_id)
      end
      assert_match /already completed/, err.message
    end

    should "raise when a required cell lacks an agreed rating" do
      cap = SecureRandom.uuid_v7
      err = assert_raises(RuntimeError) do
        @aggregate.complete_alignment(@cycle_id, completed_by_id: @completed_by_id,
          required_cell_keys: [ [ cap, 1 ] ])
      end
      assert_match /1 current-level cell lacks an agreed rating/, err.message
    end

    should "complete when every required cell carries an agreed rating" do
      cap = SecureRandom.uuid_v7
      @aggregate.align_assessment(cap, level_ordinal: 1,
        aligned_frequency: "consistent", cycle_id: @cycle_id)

      @aggregate.complete_alignment(@cycle_id, completed_by_id: @completed_by_id,
        required_cell_keys: [ [ cap, 1 ] ])

      assert_kind_of PersonDevelopment::Events::FullAlignmentCompleted,
        @aggregate.unpublished_events.to_a.last
    end

    should "re-raise when a required cell's agreed rating was cleared before completion" do
      cap = SecureRandom.uuid_v7
      @aggregate.align_assessment(cap, level_ordinal: 1,
        aligned_frequency: "consistent", cycle_id: @cycle_id)
      @aggregate.clear_alignment_rating(cap, level_ordinal: 1, cycle_id: @cycle_id)

      err = assert_raises(RuntimeError) do
        @aggregate.complete_alignment(@cycle_id, completed_by_id: @completed_by_id,
          required_cell_keys: [ [ cap, 1 ] ])
      end
      assert_match /lacks an agreed rating/, err.message
    end

    should "freeze align_assessment after completion" do
      @aggregate.complete_alignment(@cycle_id, completed_by_id: @completed_by_id)

      err = assert_raises(RuntimeError) do
        @aggregate.align_assessment(SecureRandom.uuid_v7, level_ordinal: 1,
          aligned_frequency: "some", cycle_id: @cycle_id)
      end
      assert_match /Alignment has been completed/, err.message
    end

    should "reset completion state when a new cycle is joined" do
      @aggregate.complete_alignment(@cycle_id, completed_by_id: @completed_by_id)
      @aggregate.leave_cycle(@cycle_id, "completed")

      new_cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(new_cycle_id, 2)
      @aggregate.start_alignment(new_cycle_id, started_by_id: @completed_by_id)

      assert_nothing_raised do
        @aggregate.align_assessment(SecureRandom.uuid_v7, level_ordinal: 1,
          aligned_frequency: "some", cycle_id: new_cycle_id)
      end
    end
  end

  context "#reopen_alignment" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(@cycle_id, 1)
      @aggregate.start_alignment(@cycle_id, started_by_id: SecureRandom.uuid_v7)
      @cap_sid = SecureRandom.uuid_v7
      @aggregate.align_assessment(@cap_sid, level_ordinal: 2,
        aligned_frequency: "consistent", cycle_id: @cycle_id)
      @aggregate.complete_alignment(@cycle_id, completed_by_id: SecureRandom.uuid_v7)
      @reopened_by_id = SecureRandom.uuid_v7
    end

    should "apply AlignmentReopened event with cycle_id and reopened_by_id" do
      @aggregate.reopen_alignment(@cycle_id, reopened_by_id: @reopened_by_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::AlignmentReopened, event
      assert_equal @cycle_id, event.data[:cycle_id]
      assert_equal @reopened_by_id, event.data[:reopened_by_id]
    end

    should "lift the completion freeze so align_assessment is permitted again" do
      @aggregate.reopen_alignment(@cycle_id, reopened_by_id: @reopened_by_id)

      assert_nothing_raised do
        @aggregate.align_assessment(SecureRandom.uuid_v7, level_ordinal: 1,
          aligned_frequency: "some", cycle_id: @cycle_id)
      end
    end

    should "preserve previously agreed values (no clearing)" do
      @aggregate.reopen_alignment(@cycle_id, reopened_by_id: @reopened_by_id)

      aligned = @aggregate.instance_variable_get(:@aligned_ratings)
      assert_equal "consistent", aligned[[ @cap_sid, 2 ]]
    end

    should "allow re-completion after re-opening" do
      @aggregate.reopen_alignment(@cycle_id, reopened_by_id: @reopened_by_id)

      assert_nothing_raised do
        @aggregate.complete_alignment(@cycle_id, completed_by_id: SecureRandom.uuid_v7)
      end
      assert_kind_of PersonDevelopment::Events::FullAlignmentCompleted,
        @aggregate.unpublished_events.to_a.last
    end

    should "raise if alignment is not completed (still aligning)" do
      aggregate = PersonDevelopment::Aggregate.new
      aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      cycle_id = SecureRandom.uuid_v7
      aggregate.join_cycle(cycle_id, 1)
      aggregate.start_alignment(cycle_id, started_by_id: SecureRandom.uuid_v7)

      err = assert_raises(RuntimeError) do
        aggregate.reopen_alignment(cycle_id, reopened_by_id: @reopened_by_id)
      end
      assert_match(/not completed/, err.message)
    end

    should "raise if alignment has not been started" do
      aggregate = PersonDevelopment::Aggregate.new
      aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      cycle_id = SecureRandom.uuid_v7
      aggregate.join_cycle(cycle_id, 1)

      err = assert_raises(RuntimeError) do
        aggregate.reopen_alignment(cycle_id, reopened_by_id: @reopened_by_id)
      end
      assert_match(/has not been started/, err.message)
    end

    should "raise when the cycle_id does not match the current cycle" do
      err = assert_raises(RuntimeError) do
        @aggregate.reopen_alignment(SecureRandom.uuid_v7, reopened_by_id: @reopened_by_id)
      end
      assert_match(/cycle/i, err.message)
    end

    should "reconstruct the re-opened (un-completed) state on replay" do
      stream = [
        PersonDevelopment::Events::PersonAssignedToFramework.new(data: {
          person_id: @person_id, framework_id: @framework_id,
          role_id: @role_id, level_id: @level_id
        }),
        PersonDevelopment::Events::JoinedAssessmentCycle.new(data: {
          cycle_id: @cycle_id, framework_version: 1
        }),
        PersonDevelopment::Events::AlignmentStarted.new(data: {
          cycle_id: @cycle_id, started_by_id: SecureRandom.uuid_v7
        }),
        PersonDevelopment::Events::AssessmentAligned.new(data: {
          capability_stable_id: @cap_sid, level_ordinal: 2,
          aligned_frequency: "consistent", cycle_id: @cycle_id, comment: nil,
          aligned_by_id: SecureRandom.uuid_v7
        }),
        PersonDevelopment::Events::FullAlignmentCompleted.new(data: {
          cycle_id: @cycle_id, completed_by_id: SecureRandom.uuid_v7, framework_version: 1
        }),
        PersonDevelopment::Events::AlignmentReopened.new(data: {
          cycle_id: @cycle_id, reopened_by_id: @reopened_by_id
        })
      ]
      replayed = PersonDevelopment::Aggregate.new
      stream.each { |event| replayed.apply(event) }

      # Completion freeze lifted, agreed value preserved.
      assert_equal "consistent",
        replayed.instance_variable_get(:@aligned_ratings)[[ @cap_sid, 2 ]]
      assert_nothing_raised do
        replayed.align_assessment(SecureRandom.uuid_v7, level_ordinal: 1,
          aligned_frequency: "some", cycle_id: @cycle_id)
      end
    end
  end

  # ── Evidence ──

  context "#record_evidence" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @evidence_id = SecureRandom.uuid_v7
      @cap_sid = SecureRandom.uuid_v7
      @author_id = SecureRandom.uuid_v7
    end

    should "apply EvidenceRecorded event with full payload" do
      @aggregate.record_evidence(@evidence_id,
        capability_stable_id: @cap_sid,
        level_ordinal: 3,
        source: "self",
        evidence_type: "project_outcome",
        content: "Shipped X",
        author_id: @author_id,
        title: "Migration done",
        external_reference: { system: "github", url: "https://github.com/x/y/pull/1" }, valence: "demonstrated")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::EvidenceRecorded, event
      assert_equal @evidence_id, event.data[:evidence_id]
      assert_equal @cap_sid, event.data[:capability_stable_id]
      assert_equal 3, event.data[:level_ordinal]
      assert_equal "self", event.data[:source]
      assert_equal "project_outcome", event.data[:evidence_type]
      assert_equal "Shipped X", event.data[:content]
      assert_equal @author_id, event.data[:author_id]
      assert_equal "self", event.data[:feedback_direction]
      assert_equal "Migration done", event.data[:title]
      assert_equal "github", event.data[:external_reference][:system]
      assert_nil event.data[:cycle_id]
    end

    should "record an unplaced item when no cell is given, and place it through add_evidence_link" do
      @aggregate.record_evidence(@evidence_id,
        source: "peer", evidence_type: "peer_feedback", content: "Great incident call",
        author_id: @author_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::EvidenceRecorded, event
      assert_nil event.data[:capability_stable_id]
      assert_nil event.data[:level_ordinal]
      assert_nil event.data[:valence]
      assert_equal "peer_to_peer", event.data[:feedback_direction]

      @aggregate.add_evidence_link(@evidence_id,
        capability_stable_id: @cap_sid, level_ordinal: 3, linked_by_id: @author_id, valence: "demonstrated")
      assert_kind_of PersonDevelopment::Events::EvidenceLinkAdded, @aggregate.unpublished_events.to_a.last

      # Placed now: the last-link rule applies from here on.
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.remove_evidence_link(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 3, removed_by_id: @author_id)
      end
      assert_match /Cannot remove the only link/, err.message
    end

    should "carry the request it answers, and nil otherwise" do
      @aggregate.record_evidence(@evidence_id,
        source: "peer", evidence_type: "peer_feedback", content: "x", author_id: @author_id)
      assert_nil @aggregate.unpublished_events.to_a.last.data[:request_id]

      request_id = SecureRandom.uuid_v7
      @aggregate.record_evidence(SecureRandom.uuid_v7,
        capability_stable_id: @cap_sid, level_ordinal: 3, valence: "demonstrated", request_id: request_id,
        source: "peer", evidence_type: "peer_feedback", content: "x", author_id: @author_id)
      assert_equal request_id, @aggregate.unpublished_events.to_a.last.data[:request_id]
    end

    should "raise when only one half of the cell is given" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, source: "peer", evidence_type: "peer_feedback",
          content: "x", author_id: @author_id, valence: "demonstrated")
      end
      assert_match /both a capability and a level/, err.message
    end

    should "raise when a valence or additional links arrive without a cell" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          source: "peer", evidence_type: "peer_feedback", content: "x", author_id: @author_id,
          valence: "demonstrated")
      end
      assert_match /Valence needs a capability and level/, err.message

      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          source: "peer", evidence_type: "peer_feedback", content: "x", author_id: @author_id,
          additional_links: [ { capability_stable_id: @cap_sid, level_ordinal: 3, valence: "demonstrated" } ])
      end
      assert_match /Additional links need a first link/, err.message
    end

    should "attribute evidence to the current cycle unless an explicit cycle is supplied" do
      current_cycle_id = SecureRandom.uuid_v7
      original_cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(current_cycle_id, 1)

      @aggregate.record_evidence(@evidence_id,
        capability_stable_id: @cap_sid, level_ordinal: 3, source: "self",
        evidence_type: "project_outcome", content: "current", author_id: @author_id,
        valence: "demonstrated")
      assert_equal current_cycle_id, @aggregate.unpublished_events.to_a.last.data[:cycle_id]

      @aggregate.record_evidence(SecureRandom.uuid_v7,
        capability_stable_id: @cap_sid, level_ordinal: 3, source: "peer",
        evidence_type: "peer_feedback", content: "late response", author_id: @author_id,
        valence: "demonstrated", cycle_id: original_cycle_id)
      assert_equal original_cycle_id, @aggregate.unpublished_events.to_a.last.data[:cycle_id]
    end

    should "raise if not assigned to a framework" do
      bare = PersonDevelopment::Aggregate.new
      err = assert_raises(RuntimeError) do
        bare.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: "self",
          evidence_type: "project_outcome", content: "x", author_id: @author_id, valence: "demonstrated")
      end
      assert_match /not yet assigned/, err.message
    end

    should "raise on duplicate evidence_id" do
      @aggregate.record_evidence(@evidence_id,
        capability_stable_id: @cap_sid, level_ordinal: 3, source: "self",
        evidence_type: "project_outcome", content: "x", author_id: @author_id, valence: "demonstrated")

      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 3, source: "self",
          evidence_type: "project_outcome", content: "y", author_id: @author_id, valence: "demonstrated")
      end
      assert_match /already exists/, err.message
    end

    should "raise on invalid source" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: "stranger",
          evidence_type: "project_outcome", content: "x", author_id: @author_id, valence: "demonstrated")
      end
      assert_match /Invalid evidence source/, err.message
    end

    should "raise on invalid feedback direction" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: "peer",
          evidence_type: "peer_feedback", content: "x", author_id: @author_id,
          feedback_direction: "sideways", valence: "demonstrated")
      end
      assert_match /Invalid feedback direction/, err.message
    end

    should "raise on a feedback direction incompatible with its source" do
      {
        "self" => "report_to_manager",
        "manager" => "peer_to_peer",
        "peer" => "manager_to_report"
      }.each do |source, direction|
        err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
          @aggregate.record_evidence(@evidence_id,
            capability_stable_id: @cap_sid, level_ordinal: 1, source: source,
            evidence_type: "peer_feedback", content: "x", author_id: @author_id,
            feedback_direction: direction, valence: "demonstrated")
        end
        assert_match /Invalid feedback direction/, err.message
      end
    end

    should "preserve every feedback direction compatible with its source" do
      [
        [ "self", "self" ],
        [ "manager", "manager_to_report" ],
        [ "peer", "peer_to_peer" ],
        [ "peer", "report_to_manager" ]
      ].each do |source, direction|
        @aggregate.record_evidence(SecureRandom.uuid_v7,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: source,
          evidence_type: "peer_feedback", content: "x", author_id: @author_id,
          feedback_direction: direction, valence: "demonstrated")

        assert_equal direction, @aggregate.unpublished_events.to_a.last.data[:feedback_direction]
      end
    end

    should "raise on invalid evidence_type" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: "self",
          evidence_type: "garbage", content: "x", author_id: @author_id, valence: "demonstrated")
      end
      assert_match /Invalid evidence type/, err.message
    end

    should "raise when type is 'other' but custom_type_label is missing" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: "self",
          evidence_type: "other", content: "x", author_id: @author_id, valence: "demonstrated")
      end
      assert_match /Custom type label required/, err.message
    end

    should "raise when type is not 'other' but custom_type_label is given" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: "self",
          evidence_type: "code_review", content: "x", author_id: @author_id,
          custom_type_label: "Mislabeled", valence: "demonstrated")
      end
      assert_match /only allowed when evidence_type is 'other'/, err.message
    end

    should "raise on blank content" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: "self",
          evidence_type: "project_outcome", content: "   ", author_id: @author_id, valence: "demonstrated")
      end
      assert_match /content cannot be blank/, err.message
    end

    should "be allowed without joining a cycle" do
      assert_nothing_raised do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: "self",
          evidence_type: "project_outcome", content: "x", author_id: @author_id, valence: "demonstrated")
      end
    end

    should "be allowed during alignment (no freeze)" do
      cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(cycle_id, 1)
      @aggregate.rate_self(@cap_sid, level_ordinal: 3, frequency: "consistent", cycle_id: cycle_id)
      @aggregate.start_alignment(cycle_id, started_by_id: @author_id)

      assert_nothing_raised do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 3, source: "manager",
          evidence_type: "code_review", content: "Late evidence", author_id: @author_id, valence: "demonstrated")
      end
    end
  end

  context "#set_evidence_link_valence" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @evidence_id = SecureRandom.uuid_v7
      @cap_sid = SecureRandom.uuid_v7
      @author_id = SecureRandom.uuid_v7
      @aggregate.record_evidence(@evidence_id,
        capability_stable_id: @cap_sid, level_ordinal: 3, source: "self",
        evidence_type: "project_outcome", content: "x", author_id: @author_id, valence: "demonstrated")
    end

    should "apply EvidenceLinkRevalenced carrying previous and new valence" do
      @aggregate.set_evidence_link_valence(@evidence_id,
        capability_stable_id: @cap_sid, level_ordinal: 3,
        valence: "growth_area", changed_by_id: @author_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::EvidenceLinkRevalenced, event
      assert_equal @evidence_id, event.data[:evidence_id]
      assert_equal @cap_sid, event.data[:capability_stable_id]
      assert_equal 3, event.data[:level_ordinal]
      assert_equal "demonstrated", event.data[:previous_valence]
      assert_equal "growth_area", event.data[:valence]
      assert_equal @author_id, event.data[:changed_by_id]
    end

    should "carry the accepted suggestion's id, and omit the key otherwise" do
      suggestion_id = SecureRandom.uuid_v7
      @aggregate.set_evidence_link_valence(@evidence_id,
        capability_stable_id: @cap_sid, level_ordinal: 3,
        valence: "growth_area", changed_by_id: @author_id, via_suggestion_id: suggestion_id)
      assert_equal suggestion_id, @aggregate.unpublished_events.to_a.last.data[:via_suggestion_id]

      @aggregate.set_evidence_link_valence(@evidence_id,
        capability_stable_id: @cap_sid, level_ordinal: 3,
        valence: "demonstrated", changed_by_id: @author_id)
      assert_not @aggregate.unpublished_events.to_a.last.data.key?(:via_suggestion_id)
    end

    should "be a no-op when the link already carries that valence" do
      before = @aggregate.unpublished_events.to_a.size
      @aggregate.set_evidence_link_valence(@evidence_id,
        capability_stable_id: @cap_sid, level_ordinal: 3,
        valence: "demonstrated", changed_by_id: @author_id)
      assert_equal before, @aggregate.unpublished_events.to_a.size
    end

    should "raise for a coordinate the item is not linked to" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.set_evidence_link_valence(@evidence_id,
          capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 3,
          valence: "growth_area", changed_by_id: @author_id)
      end
      assert_match(/not linked to that coordinate/, err.message)
    end

    should "raise for an invalid valence" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.set_evidence_link_valence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 3,
          valence: "negative", changed_by_id: @author_id)
      end
      assert_match(/Invalid evidence valence/, err.message)
    end

    should "raise for withdrawn evidence" do
      @aggregate.withdraw_evidence(@evidence_id, withdrawn_by_id: @author_id)
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.set_evidence_link_valence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 3,
          valence: "growth_area", changed_by_id: @author_id)
      end
      assert_match(/withdrawn/, err.message)
    end

    should "accept the survivor stable_id after an evolved migration" do
      survivor = SecureRandom.uuid_v7
      @aggregate.migrate_framework_version(@framework_id, 1, 2, [
        { from_stable_id: @cap_sid, to_stable_id: survivor,
          mapping_type: "evolved", requires_reassessment: false }
      ])

      # The read model re-keys links to the survivor id, so commands
      # arrive with it — the aggregate's link map must have followed.
      @aggregate.set_evidence_link_valence(@evidence_id,
        capability_stable_id: survivor, level_ordinal: 3,
        valence: "growth_area", changed_by_id: @author_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::EvidenceLinkRevalenced, event
      assert_equal survivor, event.data[:capability_stable_id]

      # And the old id no longer resolves — no duplicate logical linkage.
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.set_evidence_link_valence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 3,
          valence: "growth_area", changed_by_id: @author_id)
      end
      assert_match(/not linked to that coordinate/, err.message)
    end
  end

  context "record_evidence with additional_links" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @evidence_id = SecureRandom.uuid_v7
      @cap_sid = SecureRandom.uuid_v7
      @cap_sid2 = SecureRandom.uuid_v7
      @author_id = SecureRandom.uuid_v7
    end

    should "apply EvidenceRecorded then one EvidenceLinkAdded per additional link" do
      @aggregate.record_evidence(@evidence_id,
        capability_stable_id: @cap_sid, level_ordinal: 3, source: "self",
        evidence_type: "project_outcome", content: "x", author_id: @author_id,
        additional_links: [
          { capability_stable_id: @cap_sid2, level_ordinal: 4, valence: "growth_area" },
          { capability_stable_id: @cap_sid, level_ordinal: 2, valence: "demonstrated" }
        ], valence: "demonstrated")

      events = @aggregate.unpublished_events.to_a
      recorded = events.select { |e| e.is_a?(PersonDevelopment::Events::EvidenceRecorded) }
      added = events.select { |e| e.is_a?(PersonDevelopment::Events::EvidenceLinkAdded) }
      assert_equal 1, recorded.size
      assert_equal 2, added.size
      assert_equal [ [ @cap_sid2, 4 ], [ @cap_sid, 2 ] ],
        added.map { |e| [ e.data[:capability_stable_id], e.data[:level_ordinal] ] }
    end

    should "reject an additional link that duplicates the first link" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 3, source: "self",
          evidence_type: "project_outcome", content: "x", author_id: @author_id,
          additional_links: [ { capability_stable_id: @cap_sid, level_ordinal: 3, valence: "demonstrated" } ], valence: "demonstrated")
      end
      assert_match /already linked to that coordinate/, err.message
    end
  end

  context "#add_evidence_link / #remove_evidence_link" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @evidence_id = SecureRandom.uuid_v7
      @cap_sid = SecureRandom.uuid_v7
      @new_cap_sid = SecureRandom.uuid_v7
      @author_id = SecureRandom.uuid_v7
      @aggregate.record_evidence(@evidence_id,
        capability_stable_id: @cap_sid, level_ordinal: 3, source: "self",
        evidence_type: "project_outcome", content: "x", author_id: @author_id, valence: "demonstrated")
    end

    should "apply EvidenceLinkAdded with the new coordinate" do
      @aggregate.add_evidence_link(@evidence_id,
        capability_stable_id: @new_cap_sid, level_ordinal: 4,
        linked_by_id: @author_id, rationale: "Also applies", valence: "demonstrated")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::EvidenceLinkAdded, event
      assert_equal @evidence_id, event.data[:evidence_id]
      assert_equal @new_cap_sid, event.data[:capability_stable_id]
      assert_equal 4, event.data[:level_ordinal]
      assert_equal "Also applies", event.data[:rationale]
      assert_equal "demonstrated", event.data[:valence]
      assert_not event.data.key?(:via_suggestion_id)
    end

    should "carry the accepted suggestion's id on the link" do
      suggestion_id = SecureRandom.uuid_v7
      @aggregate.add_evidence_link(@evidence_id,
        capability_stable_id: @new_cap_sid, level_ordinal: 4,
        linked_by_id: @author_id, valence: "demonstrated", via_suggestion_id: suggestion_id)

      assert_equal suggestion_id, @aggregate.unpublished_events.to_a.last.data[:via_suggestion_id]
    end

    should "raise when adding a link without a valid valence" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.add_evidence_link(@evidence_id,
          capability_stable_id: @new_cap_sid, level_ordinal: 4, linked_by_id: @author_id, valence: "positive")
      end
      assert_match(/Invalid evidence valence/, err.message)
    end

    should "raise when adding a duplicate link" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.add_evidence_link(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 3, linked_by_id: @author_id, valence: "demonstrated")
      end
      assert_match /already linked to that coordinate/, err.message
    end

    should "raise when adding a link to withdrawn evidence" do
      @aggregate.withdraw_evidence(@evidence_id, withdrawn_by_id: @author_id)
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.add_evidence_link(@evidence_id,
          capability_stable_id: @new_cap_sid, level_ordinal: 4, linked_by_id: @author_id, valence: "demonstrated")
      end
      assert_match /withdrawn evidence/, err.message
    end

    should "apply EvidenceLinkRemoved when the item has more than one link" do
      @aggregate.add_evidence_link(@evidence_id,
        capability_stable_id: @new_cap_sid, level_ordinal: 4, linked_by_id: @author_id, valence: "demonstrated")
      @aggregate.remove_evidence_link(@evidence_id,
        capability_stable_id: @cap_sid, level_ordinal: 3, removed_by_id: @author_id, reason: "Mislinked")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::EvidenceLinkRemoved, event
      assert_equal @cap_sid, event.data[:capability_stable_id]
      assert_equal 3, event.data[:level_ordinal]
      assert_equal "Mislinked", event.data[:reason]
    end

    should "raise when removing a link the item does not have" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.remove_evidence_link(@evidence_id,
          capability_stable_id: @new_cap_sid, level_ordinal: 4, removed_by_id: @author_id)
      end
      assert_match /not linked to that coordinate/, err.message
    end

    should "raise when removing the only remaining link" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.remove_evidence_link(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 3, removed_by_id: @author_id)
      end
      assert_match /Cannot remove the only link/, err.message
    end
  end

  context "historical EvidenceRelinked replay" do
    should "reconstruct a single active link (remove previous, add new)" do
      person_id = SecureRandom.uuid_v7
      framework_id = SecureRandom.uuid_v7
      evidence_id = SecureRandom.uuid_v7
      cap_a = SecureRandom.uuid_v7
      cap_b = SecureRandom.uuid_v7
      author_id = SecureRandom.uuid_v7

      stream = [
        PersonDevelopment::Events::PersonAssignedToFramework.new(data: {
          person_id: person_id, framework_id: framework_id,
          role_id: @role_id, level_id: @level_id
        }),
        PersonDevelopment::Events::EvidenceRecorded.new(data: {
          evidence_id: evidence_id, capability_stable_id: cap_a, level_ordinal: 3,
          source: "self", evidence_type: "project_outcome", custom_type_label: nil,
          title: nil, content: "x", external_reference: nil, author_id: author_id
        }),
        PersonDevelopment::Events::EvidenceRelinked.new(data: {
          evidence_id: evidence_id,
          previous_capability_stable_id: cap_a, previous_level_ordinal: 3,
          new_capability_stable_id: cap_b, new_level_ordinal: 4,
          relinked_by_id: author_id, rationale: nil
        })
      ]
      replayed = PersonDevelopment::Aggregate.new
      stream.each { |event| replayed.apply(event) }

      # The new coordinate is now the sole link, so adding it again raises
      # (duplicate) while the old coordinate can be re-added freely.
      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        replayed.add_evidence_link(evidence_id,
          capability_stable_id: cap_b, level_ordinal: 4, linked_by_id: author_id, valence: "demonstrated")
      end
      assert_nothing_raised do
        replayed.add_evidence_link(evidence_id,
          capability_stable_id: cap_a, level_ordinal: 3, linked_by_id: author_id, valence: "demonstrated")
      end
    end
  end

  context "#withdraw_evidence" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @evidence_id = SecureRandom.uuid_v7
      @cap_sid = SecureRandom.uuid_v7
      @author_id = SecureRandom.uuid_v7
      @aggregate.record_evidence(@evidence_id,
        capability_stable_id: @cap_sid, level_ordinal: 3, source: "self",
        evidence_type: "project_outcome", content: "x", author_id: @author_id, valence: "demonstrated")
    end

    should "apply EvidenceWithdrawn with reason" do
      @aggregate.withdraw_evidence(@evidence_id, withdrawn_by_id: @author_id, reason: "Wrong context")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::EvidenceWithdrawn, event
      assert_equal @evidence_id, event.data[:evidence_id]
      assert_equal @author_id, event.data[:withdrawn_by_id]
      assert_equal "Wrong context", event.data[:reason]
    end

    should "raise on unknown evidence_id" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.withdraw_evidence(SecureRandom.uuid_v7, withdrawn_by_id: @author_id)
      end
      assert_match /No evidence with id/, err.message
    end

    should "raise when already withdrawn" do
      @aggregate.withdraw_evidence(@evidence_id, withdrawn_by_id: @author_id)
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.withdraw_evidence(@evidence_id, withdrawn_by_id: @author_id)
      end
      assert_match /already withdrawn/, err.message
    end
  end

  context "#update_evidence" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @evidence_id = SecureRandom.uuid_v7
      @cap_sid = SecureRandom.uuid_v7
      @author_id = SecureRandom.uuid_v7
      @aggregate.record_evidence(@evidence_id,
        capability_stable_id: @cap_sid, level_ordinal: 3, source: "self",
        evidence_type: "project_outcome", content: "Original",
        title: "Old title", author_id: @author_id, valence: "demonstrated")
    end

    should "apply EvidenceUpdated with the new field values" do
      @aggregate.update_evidence(@evidence_id,
        title: "New title",
        content: "Updated content",
        evidence_type: "code_review",
        custom_type_label: nil,
        external_reference: { system: "github", url: "https://github.com/x/y/pull/2" },
        edited_by_id: @author_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::EvidenceUpdated, event
      assert_equal @evidence_id, event.data[:evidence_id]
      assert_equal "New title", event.data[:title]
      assert_equal "Updated content", event.data[:content]
      assert_equal "code_review", event.data[:evidence_type]
      assert_nil event.data[:custom_type_label]
      assert_equal "github", event.data[:external_reference][:system]
      assert_equal @author_id, event.data[:edited_by_id]
    end

    should "raise on unknown evidence_id" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.update_evidence(SecureRandom.uuid_v7,
          title: nil, content: "x", evidence_type: "project_outcome",
          custom_type_label: nil, external_reference: nil, edited_by_id: @author_id)
      end
      assert_match /No evidence with id/, err.message
    end

    should "raise when evidence has been withdrawn" do
      @aggregate.withdraw_evidence(@evidence_id, withdrawn_by_id: @author_id)
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.update_evidence(@evidence_id,
          title: nil, content: "x", evidence_type: "project_outcome",
          custom_type_label: nil, external_reference: nil, edited_by_id: @author_id)
      end
      assert_match /withdrawn/, err.message
    end

    should "raise on invalid evidence_type" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.update_evidence(@evidence_id,
          title: nil, content: "x", evidence_type: "garbage",
          custom_type_label: nil, external_reference: nil, edited_by_id: @author_id)
      end
      assert_match /Invalid evidence type/, err.message
    end

    should "raise when type is 'other' but custom_type_label is missing" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.update_evidence(@evidence_id,
          title: nil, content: "x", evidence_type: "other",
          custom_type_label: nil, external_reference: nil, edited_by_id: @author_id)
      end
      assert_match /Custom type label required/, err.message
    end

    should "raise when type is non-'other' but custom_type_label is given" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.update_evidence(@evidence_id,
          title: nil, content: "x", evidence_type: "code_review",
          custom_type_label: "stray", external_reference: nil, edited_by_id: @author_id)
      end
      assert_match /only allowed when evidence_type is 'other'/, err.message
    end

    should "raise on blank content" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.update_evidence(@evidence_id,
          title: nil, content: "   ", evidence_type: "project_outcome",
          custom_type_label: nil, external_reference: nil, edited_by_id: @author_id)
      end
      assert_match /content cannot be blank/, err.message
    end

    should "be allowed during alignment (no freeze)" do
      cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(cycle_id, 1)
      @aggregate.rate_self(@cap_sid, level_ordinal: 3, frequency: "consistent", cycle_id: cycle_id)
      @aggregate.start_alignment(cycle_id, started_by_id: @author_id)

      assert_nothing_raised do
        @aggregate.update_evidence(@evidence_id,
          title: nil, content: "Late edit", evidence_type: "code_review",
          custom_type_label: nil, external_reference: nil, edited_by_id: @author_id)
      end
    end
  end
end
