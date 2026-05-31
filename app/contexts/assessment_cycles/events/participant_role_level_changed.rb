# frozen_string_literal: true

# Event emitted when an enrolled participant's assessed role/level changes
# WHILE the cycle is open — e.g. a promotion (level change) or transfer (role
# change) lands mid-cycle. Lets the AssessmentCycle aggregate own each
# participant's assessed role/level as a first-class fact, so cohort statistics
# are answerable cycle-side without cross-checking PersonDev streams.
#
# Emitted by the `update_participant_role` command, which is issued by the
# cross-stream {AssessmentCycles::SyncHandlers::ParticipantRoleSync} handler in
# response to {PersonDevelopment::Events::PersonLevelChanged} /
# {PersonDevelopment::Events::PersonRoleChanged}. The aggregate guards that the
# cycle is open and the person enrolled, and no-ops when role+level are
# unchanged (so repeat HRIS syncs don't emit redundant events). A change after
# the cycle closes does NOT emit — closed cycles stay frozen at their last
# assessed level.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :cycle_id UUID of the cycle
#   @option data [String] :person_id UUID of the participant
#   @option data [String] :role_id new role being assessed against
#   @option data [String] :level_id new level being assessed against
#   @option data [String] :reason why the change occurred (e.g. "hris_sync")
#
class AssessmentCycles::Events::ParticipantRoleLevelChanged < RubyEventStore::Event
end
