# frozen_string_literal: true

require "test_helper"

# Per-role alignment (ADR-22): alignment is started, completed and re-opened
# against a role, freezes the cells that role reads, and a start carrying no
# role or cells — every event before per-role alignment — keeps freezing the
# whole assessment.
class PersonDevelopment::AggregateRoleAlignmentTest < ActiveSupport::TestCase
  setup do
    @aggregate = PersonDevelopment::Aggregate.new
    @home_role = SecureRandom.uuid_v7
    @pm_role = SecureRandom.uuid_v7
    @aggregate.assign_to_framework(SecureRandom.uuid_v7, SecureRandom.uuid_v7, @home_role, SecureRandom.uuid_v7)
    @cycle_id = SecureRandom.uuid_v7
    @aggregate.join_cycle(@cycle_id, 1)
    @manager = SecureRandom.uuid_v7

    @shared = [ SecureRandom.uuid_v7, 3 ]
    @home_only = [ SecureRandom.uuid_v7, 3 ]
    @pm_only = [ SecureRandom.uuid_v7, 3 ]
    @home_cells = [ @shared, @home_only ]
    @pm_cells = [ @shared, @pm_only ]
  end

  def start(role_id, cells, level_ordinal: 3)
    @aggregate.start_alignment(@cycle_id, started_by_id: @manager, role_id: role_id,
                               cell_keys: cells, level_ordinal: level_ordinal)
  end

  def rate_both(cell, frequency, source: "human")
    stable_id, ordinal = cell
    @aggregate.rate_self(stable_id, level_ordinal: ordinal, frequency: frequency, cycle_id: @cycle_id, source: source)
    @aggregate.rate_as_manager(stable_id, level_ordinal: ordinal, frequency: frequency, cycle_id: @cycle_id,
                               source: source)
  end

  def rate_self(cell)
    @aggregate.rate_self(cell[0], level_ordinal: cell[1], frequency: "some", cycle_id: @cycle_id)
  end

  def align(cell, frequency = "consistent")
    @aggregate.align_assessment(cell[0], level_ordinal: cell[1], aligned_frequency: frequency, cycle_id: @cycle_id)
  end

  def events_of(klass)
    @aggregate.unpublished_events.to_a.grep(klass)
  end

  context "starting" do
    should "record the role, its level and its cells on the event" do
      start(@pm_role, @pm_cells)

      event = events_of(PersonDevelopment::Events::AlignmentStarted).last
      assert_equal @pm_role, event.data[:role_id]
      assert_equal 3, event.data[:level_ordinal]
      assert_equal @pm_cells, event.data[:cell_keys]
    end

    should "default the role to the one the cycle assesses" do
      @aggregate.start_alignment(@cycle_id, started_by_id: @manager, cell_keys: @home_cells)

      assert_equal @home_role, events_of(PersonDevelopment::Events::AlignmentStarted).last.data[:role_id]
    end

    should "follow a transfer made before alignment starts" do
      @aggregate.change_role(@pm_role, SecureRandom.uuid_v7)
      @aggregate.start_alignment(@cycle_id, started_by_id: @manager, cell_keys: @pm_cells)

      assert_equal @pm_role, events_of(PersonDevelopment::Events::AlignmentStarted).last.data[:role_id]
    end

    should "stay on the role alignment started against through a later transfer" do
      start(@pm_role, @pm_cells)
      @aggregate.change_role(@pm_role, SecureRandom.uuid_v7)
      @aggregate.start_alignment(@cycle_id, started_by_id: @manager, cell_keys: @home_cells)

      assert_equal @home_role, events_of(PersonDevelopment::Events::AlignmentStarted).last.data[:role_id]
    end

    should "refuse a second start against the same role but allow another role" do
      start(@home_role, @home_cells)

      error = assert_raises(RuntimeError) { start(@home_role, @home_cells) }
      assert_match(/already started/, error.message)
      assert_nothing_raised { start(@pm_role, @pm_cells) }
    end
  end

  context "the cell-level freeze" do
    should "freeze only the cells a started role reads" do
      start(@pm_role, @pm_cells)

      assert_raises(RuntimeError) { rate_self(@shared) }
      assert_raises(RuntimeError) { rate_self(@pm_only) }
      assert_nothing_raised { rate_self(@home_only) }
    end

    should "freeze the union of every started role's cells" do
      start(@pm_role, @pm_cells)
      start(@home_role, @home_cells)

      [ @shared, @home_only, @pm_only ].each do |cell|
        assert_raises(RuntimeError) { rate_self(cell) }
      end
    end

    should "keep the freeze through completion and lift it with a new cycle" do
      start(@pm_role, @pm_cells)
      align(@shared)
      align(@pm_only)
      @aggregate.complete_alignment(@cycle_id, completed_by_id: @manager, role_id: @pm_role)
      assert_raises(RuntimeError) { rate_self(@pm_only) }

      @aggregate.conclude_cycle(@cycle_id)
      @cycle_id = SecureRandom.uuid_v7
      @aggregate.join_cycle(@cycle_id, 1)
      assert_nothing_raised { rate_self(@pm_only) }
    end
  end

  context "history without a role" do
    setup do
      # The shape every AlignmentStarted had before per-role alignment.
      @aggregate.apply(PersonDevelopment::Events::AlignmentStarted.new(
        data: { cycle_id: @cycle_id, started_by_id: @manager }
      ))
    end

    should "freeze every cell, as it always did" do
      [ @shared, @home_only, @pm_only, [ SecureRandom.uuid_v7, 1 ] ].each do |cell|
        assert_raises(RuntimeError) { rate_self(cell) }
      end
    end

    should "be the home role's alignment" do
      error = assert_raises(RuntimeError) { start(@home_role, @home_cells) }
      assert_match(/already started/, error.message)

      align(@home_only)
      @aggregate.complete_alignment(@cycle_id, completed_by_id: @manager, role_id: @home_role)
      completed = events_of(PersonDevelopment::Events::FullAlignmentCompleted).last
      assert_equal @home_role, completed.data[:role_id]
    end

    should "complete and re-open through a historical event without a role" do
      @aggregate.apply(PersonDevelopment::Events::FullAlignmentCompleted.new(
        data: { cycle_id: @cycle_id, completed_by_id: @manager }
      ))
      assert_raises(RuntimeError) { align(@home_only) }

      @aggregate.apply(PersonDevelopment::Events::AlignmentReopened.new(
        data: { cycle_id: @cycle_id, reopened_by_id: @manager }
      ))
      assert_nothing_raised { align(@home_only) }
    end

    should "still let another role be started, whose freeze adds nothing" do
      assert_nothing_raised { start(@pm_role, @pm_cells) }
    end
  end

  context "auto-align" do
    should "agree only the started role's cells" do
      rate_both(@shared, "consistent")
      rate_both(@home_only, "some")
      rate_both(@pm_only, "occasional")

      start(@pm_role, @pm_cells)

      aligned = events_of(PersonDevelopment::Events::AssessmentAligned).map { |e|
        [ e.data[:capability_stable_id], e.data[:level_ordinal] ]
      }
      assert_equal @pm_cells.sort, aligned.sort
    end

    should "leave a cell another role's conversation already agreed" do
      rate_both(@shared, "consistent")
      start(@home_role, @home_cells)
      align(@shared, "some")

      start(@pm_role, @pm_cells)

      shared_alignments = events_of(PersonDevelopment::Events::AssessmentAligned).select { |e|
        e.data[:capability_stable_id] == @shared[0]
      }
      assert_equal [ "consistent", "some" ], shared_alignments.map { |e| e.data[:aligned_frequency] }
    end

    should "never agree a carried-forward pair" do
      rate_both(@pm_only, "consistent", source: "seeded")

      start(@pm_role, @pm_cells)

      assert_empty events_of(PersonDevelopment::Events::AssessmentAligned)
    end
  end

  context "agreeing a cell" do
    should "need an alignment in progress against a role that reads it" do
      start(@pm_role, @pm_cells)

      assert_nothing_raised { align(@pm_only) }
      error = assert_raises(RuntimeError) { align(@home_only) }
      assert_match(/role that reads this cell/, error.message)
    end

    should "be refused once that role's alignment is complete" do
      start(@pm_role, @pm_cells)
      align(@shared)
      @aggregate.complete_alignment(@cycle_id, completed_by_id: @manager, role_id: @pm_role)

      error = assert_raises(RuntimeError) { align(@pm_only) }
      assert_match(/completed/, error.message)
    end

    should "fill a cell a completed role left open, but never rewrite one it agreed" do
      start(@home_role, @home_cells)
      align(@shared)
      @aggregate.complete_alignment(@cycle_id, completed_by_id: @manager, role_id: @home_role)
      start(@pm_role, @pm_cells + [ @home_only ].map { |sid, _| [ sid, 4 ] })

      assert_raises(RuntimeError) { align(@shared, "some") }
      assert_nothing_raised { align([ @home_only[0], 4 ]) }
    end
  end

  context "completing and re-opening" do
    setup do
      start(@home_role, @home_cells)
      start(@pm_role, @pm_cells)
    end

    should "complete one role without touching the other" do
      align(@pm_only)
      @aggregate.complete_alignment(@cycle_id, completed_by_id: @manager, role_id: @pm_role,
                                    required_cell_keys: [ @pm_only ])

      assert_nothing_raised { align(@home_only) }
      error = assert_raises(RuntimeError) do
        @aggregate.complete_alignment(@cycle_id, completed_by_id: @manager, role_id: @pm_role)
      end
      assert_match(/already completed/, error.message)
    end

    should "gate completion on that role's own cells" do
      error = assert_raises(RuntimeError) do
        @aggregate.complete_alignment(@cycle_id, completed_by_id: @manager, role_id: @pm_role,
                                      required_cell_keys: @pm_cells)
      end
      assert_match(/2 current-level cells lack/, error.message)
    end

    should "re-open only the named role" do
      @aggregate.complete_alignment(@cycle_id, completed_by_id: @manager, role_id: @home_role)
      @aggregate.complete_alignment(@cycle_id, completed_by_id: @manager, role_id: @pm_role)

      @aggregate.reopen_alignment(@cycle_id, reopened_by_id: @manager, role_id: @pm_role)

      assert_equal @pm_role, events_of(PersonDevelopment::Events::AlignmentReopened).last.data[:role_id]
      assert_nothing_raised { align(@pm_only) }
      assert_raises(RuntimeError) { align(@home_only) }
    end

    should "refuse to complete or re-open a role never started" do
      other = SecureRandom.uuid_v7
      assert_raises(RuntimeError) { @aggregate.complete_alignment(@cycle_id, completed_by_id: @manager, role_id: other) }
      assert_raises(RuntimeError) { @aggregate.reopen_alignment(@cycle_id, reopened_by_id: @manager, role_id: other) }
    end
  end

  should "carry a role's frozen cells onto an evolved capability's survivor" do
    start(@pm_role, @pm_cells)
    survivor = SecureRandom.uuid_v7
    @aggregate.apply(PersonDevelopment::Events::FrameworkVersionMigrated.new(data: {
      framework_id: SecureRandom.uuid_v7, old_version: 1, new_version: 2,
      mappings: [ { from_stable_id: @pm_only[0], to_stable_id: survivor, mapping_type: "evolved" } ]
    }))

    assert_raises(RuntimeError) { rate_self([ survivor, 3 ]) }
  end
end
