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
end
