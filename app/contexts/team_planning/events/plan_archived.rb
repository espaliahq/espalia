# frozen_string_literal: true

# A plan was put aside. It keeps everything it holds and takes no change
# until it is restored, and it is no longer checked against the organisation.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :archived_by_id person_id of the editor
#   @option data [String] :archived_on ISO 8601, the tenant's today when it was archived. Missing from
#     events written before [#469](https://github.com/espaliahq/espalia/issues/469), whose day is the event's timestamp as a UTC date
#   @option data [String] :time_zone the tenant's zone, which fixes the instant archived_on ended.
#     Missing from events written before [#469](https://github.com/espaliahq/espalia/issues/469), whose day ended at midnight UTC
#
class TeamPlanning::Events::PlanArchived < RubyEventStore::Event
end
