# frozen_string_literal: true

require "test_helper"

class AssessmentCycles::AggregateTest < ActiveSupport::TestCase
  setup do
    @aggregate = AssessmentCycles::Aggregate.new
    @cycle_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @defined_by = SecureRandom.uuid_v7
  end

  context "#define" do
    should "apply CycleDefined event" do
      @aggregate.define(@cycle_id, @framework_id, "Q1 2026 Review", "regular", 1, defined_by: @defined_by)

      events = @aggregate.unpublished_events.to_a
      assert_equal 1, events.length
      assert_kind_of AssessmentCycles::Events::CycleDefined, events.first
      assert_equal @cycle_id, events.first.data[:cycle_id]
      assert_equal @framework_id, events.first.data[:framework_id]
      assert_equal 1, events.first.data[:framework_version]
      assert_equal "Q1 2026 Review", events.first.data[:name]
      assert_equal "regular", events.first.data[:cycle_type]
      assert_equal @defined_by, events.first.data[:defined_by]
    end

    should "raise if already defined" do
      @aggregate.define(@cycle_id, @framework_id, "Q1", "regular", 1)

      err = assert_raises(RuntimeError) do
        @aggregate.define(@cycle_id, @framework_id, "Q1", "regular", 1)
      end
      assert_match /already defined/, err.message
    end

    should "raise for invalid cycle_type" do
      err = assert_raises(RuntimeError) do
        @aggregate.define(@cycle_id, @framework_id, "Q1", "nonsense", 1)
      end
      assert_match /Invalid cycle type/, err.message
    end

    %w[regular performance_review promotion_review].each do |valid_type|
      should "accept #{valid_type} as a valid cycle_type" do
        @aggregate.define(@cycle_id, @framework_id, "Q1", valid_type, 1)
        assert_equal 1, @aggregate.unpublished_events.to_a.length
      end
    end
  end

  context "#enroll" do
    setup do
      @aggregate.define(@cycle_id, @framework_id, "Q1", "regular", 1)
      @person_id = SecureRandom.uuid_v7
    end

    should "apply PersonEnrolled event carrying framework metadata" do
      @aggregate.enroll(@person_id, enrolled_by: @defined_by)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::PersonEnrolled, event
      assert_equal @cycle_id, event.data[:cycle_id]
      assert_equal @person_id, event.data[:person_id]
      assert_equal @framework_id, event.data[:framework_id]
      assert_equal 1, event.data[:framework_version]
      assert_equal @defined_by, event.data[:enrolled_by]
    end

    should "raise if person already enrolled" do
      @aggregate.enroll(@person_id)

      err = assert_raises(RuntimeError) do
        @aggregate.enroll(@person_id)
      end
      assert_match /already enrolled/, err.message
    end

    should "raise if cycle not defined" do
      fresh = AssessmentCycles::Aggregate.new
      err = assert_raises(RuntimeError) do
        fresh.enroll(@person_id)
      end
      assert_match /not defined/, err.message
    end

    should "raise if cycle is closed" do
      @aggregate.close
      err = assert_raises(RuntimeError) do
        @aggregate.enroll(@person_id)
      end
      assert_match /closed/, err.message
    end
  end

  context "#unenroll" do
    setup do
      @aggregate.define(@cycle_id, @framework_id, "Q1", "regular", 1)
      @person_id = SecureRandom.uuid_v7
      @aggregate.enroll(@person_id)
    end

    should "apply PersonUnenrolled event" do
      @aggregate.unenroll(@person_id, "withdrew", unenrolled_by: @defined_by)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::PersonUnenrolled, event
      assert_equal @person_id, event.data[:person_id]
      assert_equal "withdrew", event.data[:reason]
      assert_equal @framework_id, event.data[:framework_id]
    end

    should "raise if person not enrolled" do
      err = assert_raises(RuntimeError) do
        @aggregate.unenroll(SecureRandom.uuid_v7, "nope")
      end
      assert_match /not enrolled/, err.message
    end

    should "allow re-enrolling after unenroll" do
      @aggregate.unenroll(@person_id, "withdrew")
      @aggregate.enroll(@person_id)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::PersonEnrolled, event
    end
  end

  context "#close" do
    setup do
      @aggregate.define(@cycle_id, @framework_id, "Q1", "regular", 1)
      @p1 = SecureRandom.uuid_v7
      @p2 = SecureRandom.uuid_v7
      @aggregate.enroll(@p1)
      @aggregate.enroll(@p2)
    end

    should "apply CycleClosed event with enrolled_person_ids" do
      @aggregate.close(closed_by: @defined_by)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CycleClosed, event
      assert_equal @cycle_id, event.data[:cycle_id]
      assert_equal @framework_id, event.data[:framework_id]
      assert_includes event.data[:enrolled_person_ids], @p1
      assert_includes event.data[:enrolled_person_ids], @p2
    end

    should "raise if already closed" do
      @aggregate.close
      err = assert_raises(RuntimeError) do
        @aggregate.close
      end
      assert_match /closed/, err.message
    end

    should "prevent further enrollment after close" do
      @aggregate.close
      err = assert_raises(RuntimeError) do
        @aggregate.enroll(SecureRandom.uuid_v7)
      end
      assert_match /closed/, err.message
    end
  end
end
