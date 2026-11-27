# frozen_string_literal: true

require "test_helper"

# Commands on a survivor cell after a mid-cycle publish with an `evolved`
# mapping: each one used to read the retired id and refuse.
class PersonDevelopment::AggregateRatingRekeyTest < ActiveSupport::TestCase
  MAPPINGS = [ { from_stable_id: "old", to_stable_id: "new", mapping_type: "evolved", requires_reassessment: false } ].freeze
  CELL = [ "new", 3 ].freeze

  setup do
    @aggregate = PersonDevelopment::Aggregate.new
    @aggregate.assign_to_framework("person", "framework", "role", "level")
    @aggregate.join_cycle("cycle", 1)
    @aggregate.rate_self("old", level_ordinal: 3, frequency: "some", cycle_id: "cycle")
    @aggregate.rate_as_manager("old", level_ordinal: 3, frequency: "some", cycle_id: "cycle", rated_by_id: "manager")
  end

  should "auto-align a matching pair on the survivor cell when alignment starts" do
    migrate
    start_alignment

    aligned = events(PersonDevelopment::Events::AssessmentAligned)
    assert_equal [ [ "new", 3, "some" ] ], aligned.map { |e| [ e.data[:capability_stable_id], e.data[:level_ordinal], e.data[:aligned_frequency] ] }
  end

  should "revise and clear self and manager ratings on the survivor cell" do
    migrate

    assert_nothing_raised do
      @aggregate.revise_self_rating("new", level_ordinal: 3, frequency: "consistent", rationale: "grew", cycle_id: "cycle")
      @aggregate.revise_manager_rating("new", level_ordinal: 3, frequency: "consistent", rationale: "grew", cycle_id: "cycle", rated_by_id: "manager")
      @aggregate.clear_self_rating("new", level_ordinal: 3, cycle_id: "cycle")
      @aggregate.clear_manager_rating("new", level_ordinal: 3, cycle_id: "cycle", rated_by_id: "manager")
    end
  end

  should "clear an agreed value on the survivor cell" do
    start_alignment(cell: [ "old", 3 ])
    migrate

    assert_nothing_raised do
      @aggregate.clear_alignment_rating("new", level_ordinal: 3, cycle_id: "cycle", cleared_by_id: "manager")
    end
  end

  should "count a cell agreed before the publish when alignment completes" do
    start_alignment(cell: [ "old", 3 ])
    migrate

    @aggregate.complete_alignment("cycle", completed_by_id: "manager", role_id: "role", required_cell_keys: [ CELL ])

    assert_equal 1, events(PersonDevelopment::Events::FullAlignmentCompleted).size
  end

  should "keep the survivor's own value where it was already rated at that level" do
    @aggregate.rate_self("new", level_ordinal: 3, frequency: "consistent", cycle_id: "cycle")
    migrate

    assert_equal "consistent", @aggregate.instance_variable_get(:@self_ratings)[CELL]
    assert_equal "some", @aggregate.instance_variable_get(:@self_ratings)[[ "old", 3 ]]
  end

  private

  def migrate = @aggregate.migrate_framework_version("framework", 1, 2, MAPPINGS)

  def start_alignment(cell: CELL)
    @aggregate.start_alignment("cycle", started_by_id: "manager", role_id: "role", level_ordinal: 3, cell_keys: [ cell ])
  end

  def events(klass) = @aggregate.unpublished_events.grep(klass)
end
