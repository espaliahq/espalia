# frozen_string_literal: true

# Event emitted when alignment is formally opened against a role for an
# assessment cycle.
#
# Once this event lands, self and manager ratings are frozen on the cells
# the role reads, and the manager's ratings on them are disclosed to the
# assessee (ADR-22). Issued only by the assessee's recorded reporting
# manager.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle alignment is starting on
#   @option data [String] :started_by_id UUID of the person who started alignment
#   @option data [String, nil] :role_id the role aligned against. nil on every
#     event before per-role alignment — those are the home role's.
#   @option data [Integer, nil] :level_ordinal the level of that role the
#     conversation is about. nil on history (the home level).
#   @option data [Array<Array(String, Integer)>, nil] :cell_keys the role's
#     `[capability_stable_id, level_ordinal]` cells at start — what the start
#     freezes. nil on history, which froze every cell.
#
class PersonDevelopment::Events::AlignmentStarted < RubyEventStore::Event
end
