# frozen_string_literal: true

# Someone opened a plan. It stands on the Org Graph as of its base date, read
# as known at the end of the day before.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [Shreddable::Value] :name under the plan's key
#   @option data [String] :base_on ISO 8601 date the plan stands on
#   @option data [String] :created_by_id person_id of the plan's creator
#   @option data [String] :time_zone the tenant's zone, which fixes the instant the day before the base
#     ended. Missing from events written before [#469](https://github.com/espaliahq/espalia/issues/469), whose day ended at midnight UTC
#
class TeamPlanning::Events::PlanCreated < RubyEventStore::Event
  extend Shreddable
  shreddable :name, by: :plan
end
