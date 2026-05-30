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
      @aggregate.leave_cycle(@cycle_id, "cycle_closed")
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
      assert_match /Not currently in a cycle/, err.message
    end

    should "raise if cycle_id does not match" do
      err = assert_raises(RuntimeError) do
        @aggregate.leave_cycle(SecureRandom.uuid_v7, "manual")
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
        external_reference: { system: "github", url: "https://github.com/x/y/pull/1" })

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::EvidenceRecorded, event
      assert_equal @evidence_id, event.data[:evidence_id]
      assert_equal @cap_sid, event.data[:capability_stable_id]
      assert_equal 3, event.data[:level_ordinal]
      assert_equal "self", event.data[:source]
      assert_equal "project_outcome", event.data[:evidence_type]
      assert_equal "Shipped X", event.data[:content]
      assert_equal @author_id, event.data[:author_id]
      assert_equal "Migration done", event.data[:title]
      assert_equal "github", event.data[:external_reference][:system]
    end

    should "raise if not assigned to a framework" do
      bare = PersonDevelopment::Aggregate.new
      err = assert_raises(RuntimeError) do
        bare.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: "self",
          evidence_type: "project_outcome", content: "x", author_id: @author_id)
      end
      assert_match /not yet assigned/, err.message
    end

    should "raise on duplicate evidence_id" do
      @aggregate.record_evidence(@evidence_id,
        capability_stable_id: @cap_sid, level_ordinal: 3, source: "self",
        evidence_type: "project_outcome", content: "x", author_id: @author_id)

      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 3, source: "self",
          evidence_type: "project_outcome", content: "y", author_id: @author_id)
      end
      assert_match /already exists/, err.message
    end

    should "raise on invalid source" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: "stranger",
          evidence_type: "project_outcome", content: "x", author_id: @author_id)
      end
      assert_match /Invalid evidence source/, err.message
    end

    should "raise on invalid evidence_type" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: "self",
          evidence_type: "garbage", content: "x", author_id: @author_id)
      end
      assert_match /Invalid evidence type/, err.message
    end

    should "raise when type is 'other' but custom_type_label is missing" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: "self",
          evidence_type: "other", content: "x", author_id: @author_id)
      end
      assert_match /Custom type label required/, err.message
    end

    should "raise when type is not 'other' but custom_type_label is given" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: "self",
          evidence_type: "code_review", content: "x", author_id: @author_id,
          custom_type_label: "Mislabeled")
      end
      assert_match /only allowed when evidence_type is 'other'/, err.message
    end

    should "raise on blank content" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: "self",
          evidence_type: "project_outcome", content: "   ", author_id: @author_id)
      end
      assert_match /content cannot be blank/, err.message
    end

    should "be allowed without joining a cycle" do
      assert_nothing_raised do
        @aggregate.record_evidence(@evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: "self",
          evidence_type: "project_outcome", content: "x", author_id: @author_id)
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
          evidence_type: "code_review", content: "Late evidence", author_id: @author_id)
      end
    end
  end

  context "#relink_evidence" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @evidence_id = SecureRandom.uuid_v7
      @cap_sid = SecureRandom.uuid_v7
      @new_cap_sid = SecureRandom.uuid_v7
      @author_id = SecureRandom.uuid_v7
      @aggregate.record_evidence(@evidence_id,
        capability_stable_id: @cap_sid, level_ordinal: 3, source: "self",
        evidence_type: "project_outcome", content: "x", author_id: @author_id)
    end

    should "apply EvidenceRelinked with previous and new coords" do
      @aggregate.relink_evidence(@evidence_id,
        new_capability_stable_id: @new_cap_sid, new_level_ordinal: 4,
        relinked_by_id: @author_id, rationale: "Better fit")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::EvidenceRelinked, event
      assert_equal @evidence_id, event.data[:evidence_id]
      assert_equal @cap_sid, event.data[:previous_capability_stable_id]
      assert_equal 3, event.data[:previous_level_ordinal]
      assert_equal @new_cap_sid, event.data[:new_capability_stable_id]
      assert_equal 4, event.data[:new_level_ordinal]
      assert_equal "Better fit", event.data[:rationale]
    end

    should "raise on unknown evidence_id" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.relink_evidence(SecureRandom.uuid_v7,
          new_capability_stable_id: @new_cap_sid, new_level_ordinal: 4,
          relinked_by_id: @author_id)
      end
      assert_match /No evidence with id/, err.message
    end

    should "raise when target coord is unchanged" do
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.relink_evidence(@evidence_id,
          new_capability_stable_id: @cap_sid, new_level_ordinal: 3,
          relinked_by_id: @author_id)
      end
      assert_match /already at that coordinate/, err.message
    end

    should "raise when evidence has been withdrawn" do
      @aggregate.withdraw_evidence(@evidence_id, withdrawn_by_id: @author_id)
      err = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.relink_evidence(@evidence_id,
          new_capability_stable_id: @new_cap_sid, new_level_ordinal: 4,
          relinked_by_id: @author_id)
      end
      assert_match /withdrawn evidence/, err.message
    end

    should "track new coords for subsequent operations" do
      @aggregate.relink_evidence(@evidence_id,
        new_capability_stable_id: @new_cap_sid, new_level_ordinal: 4,
        relinked_by_id: @author_id)

      # A second relink to a different coord should now compare against
      # (@new_cap_sid, 4) rather than the original. Going back to the
      # ORIGINAL coord is fine — it's a different target now.
      assert_nothing_raised do
        @aggregate.relink_evidence(@evidence_id,
          new_capability_stable_id: @cap_sid, new_level_ordinal: 3,
          relinked_by_id: @author_id)
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
        evidence_type: "project_outcome", content: "x", author_id: @author_id)
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
        title: "Old title", author_id: @author_id)
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
