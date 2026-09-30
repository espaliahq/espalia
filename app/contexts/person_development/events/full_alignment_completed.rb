# frozen_string_literal: true

# Event emitted when alignment against a role is marked complete for an
# assessment cycle.
#
# Once this event lands, the role's agreed values are the record of that
# conversation and stay frozen. For the home role the aligned values become
# the authoritative performance record for the cycle. Issued only by the
# assessee's recorded reporting manager.
#
# Snapshot point — long person-development streams compress here.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle being completed
#   @option data [String] :completed_by_id UUID of the person who completed alignment
#   @option data [Integer, nil] :framework_version the framework version this cycle
#     was assessed against at completion (the join version, advanced by any
#     mid-cycle migration). Captured so reporting can attribute a completed
#     assessment to its version without replaying the stream. nil on historical
#     events emitted before this was added.
#   @option data [String, nil] :role_id the role whose alignment completed;
#     nil on history (the home role)
#
class PersonDevelopment::Events::FullAlignmentCompleted < RubyEventStore::Event
end
