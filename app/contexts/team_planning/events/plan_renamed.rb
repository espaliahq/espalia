# frozen_string_literal: true

# A plan took a new name.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [Shreddable::Value] :name the new name, under the plan's key
#   @option data [Shreddable::Value, nil] :previous_name under the plan's key
#   @option data [String] :renamed_by_id person_id of the actor
#
class TeamPlanning::Events::PlanRenamed < RubyEventStore::Event
  extend Shreddable
  shreddable :name, :previous_name, by: :plan
end
