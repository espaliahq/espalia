# frozen_string_literal: true

# A plan was put aside. It keeps everything it holds and takes no change
# until it is restored, and it is no longer checked against the organisation.
# The day it was archived is the event's own, as a UTC date.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :archived_by_id person_id of the editor
#
class TeamPlanning::Events::PlanArchived < RubyEventStore::Event
end
