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

  context "#define with planned_end_at" do
    should "store the normalized ISO date in the event" do
      @aggregate.define(@cycle_id, @framework_id, "Q1", "regular", 1, planned_end_at: "2026-06-30")

      event = @aggregate.unpublished_events.to_a.first
      assert_equal "2026-06-30", event.data[:planned_end_at]
    end

    should "store nil when planned_end_at is omitted" do
      @aggregate.define(@cycle_id, @framework_id, "Q1", "regular", 1)
      assert_nil @aggregate.unpublished_events.to_a.first.data[:planned_end_at]
    end
  end

  context "#rename" do
    setup do
      @aggregate.define(@cycle_id, @framework_id, "Q1", "regular", 1)
    end

    should "apply CycleRenamed event" do
      @aggregate.rename("Q1 2026 Review", updated_by: @defined_by)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CycleRenamed, event
      assert_equal @cycle_id, event.data[:cycle_id]
      assert_equal "Q1 2026 Review", event.data[:new_name]
      assert_equal @defined_by, event.data[:updated_by]
    end

    should "be a no-op when the name is unchanged" do
      before = @aggregate.unpublished_events.to_a.length
      @aggregate.rename("Q1")
      assert_equal before, @aggregate.unpublished_events.to_a.length
    end

    should "raise on blank name" do
      err = assert_raises(RuntimeError) { @aggregate.rename("   ") }
      assert_match(/blank/i, err.message)
    end

    should "raise when the cycle is closed" do
      @aggregate.close
      err = assert_raises(RuntimeError) { @aggregate.rename("New name") }
      assert_match(/closed/, err.message)
    end
  end

  context "#change_type" do
    setup do
      @aggregate.define(@cycle_id, @framework_id, "Q1", "regular", 1)
    end

    should "apply CycleTypeChanged event" do
      @aggregate.change_type("promotion_review", updated_by: @defined_by)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CycleTypeChanged, event
      assert_equal "promotion_review", event.data[:new_cycle_type]
    end

    should "be a no-op when the type is unchanged" do
      before = @aggregate.unpublished_events.to_a.length
      @aggregate.change_type("regular")
      assert_equal before, @aggregate.unpublished_events.to_a.length
    end

    should "raise on invalid type" do
      err = assert_raises(RuntimeError) { @aggregate.change_type("nonsense") }
      assert_match(/Invalid cycle type/, err.message)
    end

    should "raise when the cycle is closed" do
      @aggregate.close
      err = assert_raises(RuntimeError) { @aggregate.change_type("promotion_review") }
      assert_match(/closed/, err.message)
    end
  end

  context "#set_planned_end" do
    setup do
      @aggregate.define(@cycle_id, @framework_id, "Q1", "regular", 1)
    end

    should "apply CyclePlannedEndSet event with the normalized date" do
      @aggregate.set_planned_end("2026-09-15", updated_by: @defined_by)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CyclePlannedEndSet, event
      assert_equal "2026-09-15", event.data[:planned_end_at]
    end

    should "emit nil to clear a previously-set date" do
      @aggregate.set_planned_end("2026-09-15")
      @aggregate.set_planned_end(nil)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::CyclePlannedEndSet, event
      assert_nil event.data[:planned_end_at]
    end

    should "be a no-op when the date is unchanged" do
      @aggregate.set_planned_end("2026-09-15")
      before = @aggregate.unpublished_events.to_a.length
      @aggregate.set_planned_end("2026-09-15")
      assert_equal before, @aggregate.unpublished_events.to_a.length
    end

    should "raise when the cycle is closed" do
      @aggregate.close
      err = assert_raises(RuntimeError) { @aggregate.set_planned_end("2026-09-15") }
      assert_match(/closed/, err.message)
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

  context "#roll_framework_version" do
    setup do
      @aggregate.define(@cycle_id, @framework_id, "Q1", "regular", 1)
    end

    should "apply FrameworkVersionRolled with the new version" do
      @aggregate.roll_framework_version(2)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of AssessmentCycles::Events::FrameworkVersionRolled, event
      assert_equal @cycle_id, event.data[:cycle_id]
      assert_equal @framework_id, event.data[:framework_id]
      assert_equal 2, event.data[:new_version]
    end

    should "be a no-op when the new version is not greater than the current" do
      @aggregate.roll_framework_version(2)
      events_before = @aggregate.unpublished_events.to_a.size

      @aggregate.roll_framework_version(2)
      assert_equal events_before, @aggregate.unpublished_events.to_a.size,
        "rolling to the same version should not emit a duplicate event"

      @aggregate.roll_framework_version(1)
      assert_equal events_before, @aggregate.unpublished_events.to_a.size,
        "rolling backwards should not emit an event"
    end

    should "be a no-op on a closed cycle" do
      @aggregate.close
      events_before = @aggregate.unpublished_events.to_a.size

      @aggregate.roll_framework_version(3)
      assert_equal events_before, @aggregate.unpublished_events.to_a.size,
        "closed cycles freeze the version range"
    end
  end
end
