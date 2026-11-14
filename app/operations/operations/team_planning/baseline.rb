# frozen_string_literal: true

# The organisation a plan stands on.
class Operations::TeamPlanning::Baseline < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "Get the baseline of a Team Planning plan the caller is in: the organisation on the plan's base " \
              "date, as known at the end of the day before. Units carry their parent, level and owners; people " \
              "carry their facts that day and each unit they hold, with allocation and role. People are named " \
              "by id, and `names` maps every person id the map uses to a name; a forgotten person " \
              "reads as \"#{Person::FORMER_MEMBER}\". Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, base_on, known_on, units, people, unassigned_ids, names }`
  def perform
    plan = plan!
    map = ::TeamPlanning::Baseline.new(context:, plan:).call
    { plan_id: plan.id, base_on: map.base_on.iso8601, known_on: map.known_on.iso8601,
      units: map.units.map(&:to_h),
      people: map.people.map { it.to_h.merge(memberships: it.memberships.map(&:to_h)) },
      unassigned_ids: map.unassigned_ids, names: map.names }
  end
end
