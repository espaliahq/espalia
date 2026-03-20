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

      assert_raises(RuntimeError, /already assigned/) do
        @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      end
    end
  end

  # ── Assessment Cycles ──

  context "#open_assessment_cycle" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
    end

    should "apply AssessmentCycleOpened event" do
      cycle_id = SecureRandom.uuid_v7
      @aggregate.open_assessment_cycle(cycle_id, "Q1 2026", "regular", 1)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::AssessmentCycleOpened, event
      assert_equal cycle_id, event.data[:cycle_id]
      assert_equal "Q1 2026", event.data[:cycle_name]
      assert_equal "regular", event.data[:cycle_type]
      assert_equal 1, event.data[:framework_version]
    end

    should "raise if not assigned" do
      aggregate = PersonDevelopment::Aggregate.new
      assert_raises(RuntimeError, /not yet assigned/) do
        aggregate.open_assessment_cycle(SecureRandom.uuid_v7, "Q1", "regular", 1)
      end
    end

    should "raise if cycle already open" do
      @aggregate.open_assessment_cycle(SecureRandom.uuid_v7, "Q1", "regular", 1)

      assert_raises(RuntimeError, /already open/) do
        @aggregate.open_assessment_cycle(SecureRandom.uuid_v7, "Q2", "regular", 1)
      end
    end

    should "raise for invalid cycle type" do
      assert_raises(RuntimeError, /Invalid cycle type/) do
        @aggregate.open_assessment_cycle(SecureRandom.uuid_v7, "Q1", "invalid", 1)
      end
    end
  end

  context "#complete_assessment_cycle" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.open_assessment_cycle(@cycle_id, "Q1 2026", "regular", 1)
    end

    should "apply AssessmentCycleCompleted event" do
      @aggregate.complete_assessment_cycle(@cycle_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::AssessmentCycleCompleted, event
      assert_equal @cycle_id, event.data[:cycle_id]
    end

    should "raise if wrong cycle ID" do
      assert_raises(RuntimeError, /does not match/) do
        @aggregate.complete_assessment_cycle(SecureRandom.uuid_v7)
      end
    end

    should "allow opening a new cycle after completing" do
      @aggregate.complete_assessment_cycle(@cycle_id)
      new_cycle = SecureRandom.uuid_v7
      @aggregate.open_assessment_cycle(new_cycle, "Q2 2026", "regular", 1)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::AssessmentCycleOpened, event
      assert_equal new_cycle, event.data[:cycle_id]
    end
  end

  # ── Self-Rating ──

  context "#rate_self" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.open_assessment_cycle(@cycle_id, "Q1 2026", "regular", 1)
    end

    should "apply SelfRated event with level_ordinal and frequency" do
      cap_sid = SecureRandom.uuid_v7
      @aggregate.rate_self(cap_sid, level_ordinal: 3, frequency: "consistent", comment: "Strong")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::SelfRated, event
      assert_equal cap_sid, event.data[:capability_stable_id]
      assert_equal 3, event.data[:level_ordinal]
      assert_equal "consistent", event.data[:frequency]
      assert_equal "Strong", event.data[:comment]
    end

    should "accept 'none' as a valid frequency" do
      cap_sid = SecureRandom.uuid_v7
      @aggregate.rate_self(cap_sid, level_ordinal: 2, frequency: "none")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::SelfRated, event
      assert_equal "none", event.data[:frequency]
    end

    should "raise for invalid frequency" do
      assert_raises(RuntimeError, /Invalid frequency/) do
        @aggregate.rate_self(SecureRandom.uuid_v7, level_ordinal: 1, frequency: "sometimes")
      end
    end

    should "raise if no cycle open" do
      aggregate = PersonDevelopment::Aggregate.new
      aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)

      assert_raises(RuntimeError, /No assessment cycle open/) do
        aggregate.rate_self(SecureRandom.uuid_v7, level_ordinal: 1, frequency: "some")
      end
    end
  end

  context "#revise_self_rating" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.open_assessment_cycle(@cycle_id, "Q1 2026", "regular", 1)
      @cap_sid = SecureRandom.uuid_v7
      @aggregate.rate_self(@cap_sid, level_ordinal: 3, frequency: "some")
    end

    should "apply SelfRatingRevised event" do
      @aggregate.revise_self_rating(@cap_sid, level_ordinal: 3, frequency: "consistent",
        rationale: "Reconsidered", comment: "Updated")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::SelfRatingRevised, event
      assert_equal @cap_sid, event.data[:capability_stable_id]
      assert_equal 3, event.data[:level_ordinal]
      assert_equal "consistent", event.data[:frequency]
      assert_equal "Reconsidered", event.data[:rationale]
      assert_equal "Updated", event.data[:comment]
    end

    should "raise if no prior self-rating for capability at that level" do
      assert_raises(RuntimeError, /No self-rating exists/) do
        @aggregate.revise_self_rating(@cap_sid, level_ordinal: 4, frequency: "some", rationale: "test")
      end
    end
  end

  # ── Manager Rating ──

  context "#rate_as_manager" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.open_assessment_cycle(@cycle_id, "Q1 2026", "regular", 1)
    end

    should "apply ManagerRated event" do
      cap_sid = SecureRandom.uuid_v7
      @aggregate.rate_as_manager(cap_sid, level_ordinal: 2, frequency: "occasional", comment: "Needs work")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::ManagerRated, event
      assert_equal cap_sid, event.data[:capability_stable_id]
      assert_equal 2, event.data[:level_ordinal]
      assert_equal "occasional", event.data[:frequency]
      assert_equal "Needs work", event.data[:comment]
    end

    should "raise for invalid frequency" do
      assert_raises(RuntimeError, /Invalid frequency/) do
        @aggregate.rate_as_manager(SecureRandom.uuid_v7, level_ordinal: 1, frequency: "never")
      end
    end
  end

  # ── Alignment ──

  context "#align_assessment" do
    setup do
      @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.open_assessment_cycle(@cycle_id, "Q1 2026", "regular", 1)
    end

    should "apply AssessmentAligned event" do
      cap_sid = SecureRandom.uuid_v7
      @aggregate.align_assessment(cap_sid, level_ordinal: 3, aligned_frequency: "consistent",
        comment: "We agree")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::AssessmentAligned, event
      assert_equal cap_sid, event.data[:capability_stable_id]
      assert_equal 3, event.data[:level_ordinal]
      assert_equal "consistent", event.data[:aligned_frequency]
      assert_equal "We agree", event.data[:comment]
    end

    should "raise for invalid frequency" do
      assert_raises(RuntimeError, /Invalid/) do
        @aggregate.align_assessment(SecureRandom.uuid_v7, level_ordinal: 1, aligned_frequency: "always")
      end
    end

    should "raise if no cycle open" do
      aggregate = PersonDevelopment::Aggregate.new
      aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)

      assert_raises(RuntimeError, /No assessment cycle open/) do
        aggregate.align_assessment(SecureRandom.uuid_v7, level_ordinal: 1, aligned_frequency: "some")
      end
    end
  end
end
