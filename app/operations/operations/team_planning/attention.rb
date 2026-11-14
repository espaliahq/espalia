# frozen_string_literal: true

# What no longer fits in a scenario, from {TeamPlanning::Resolution#attention}
# [#257](https://github.com/espaliahq/espalia/issues/257). An item on a person
# names them, so the forgotten-person audit walks it.
class Operations::TeamPlanning::Attention < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "List what needs attention in a scenario of a Team Planning plan the caller is in: changes that " \
              "still resolve but no longer fit, often because a scenario it follows changed later. Each item has " \
              "the subject_id and facet that no longer fit (a person's assignment, a position, a unit, a " \
              "succession, or a place's capacity as capacity:<unit or position id>, or capacity:#{::TeamPlanning::Attention::UNASSIGNED} for someone in no unit), a reason, and the change it " \
              "belongs to: its kind, the scenario that made it and its event_id. That is the later to land of the subject's own change and the change that broke it, such " \
              "as a parent unit's retirement; change is null when nothing in the plan explains it. " \
              "Once any place has a capacity model chosen, each place no model covers is listed too, except a leaver's, " \
              "a forgotten person's override and a closed position's. " \
              "Fix an item with a new change, or by pinning or clearing one. `names` maps each person id to a " \
              "name; a forgotten person reads as \"#{Person::FORMER_MEMBER}\". Refused, as an unknown plan, unless " \
              "the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, schema: { description: "The scenario, or the plan's id for the baseline. Omit it for the baseline." }

  # @return [Hash] `{ plan_id, scenario_id, items, names }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id) || plan.id
    items = refusing_bad_plans { ::TeamPlanning::Resolution.new(context:, plan:, scenario_id:).attention }
    { plan_id: plan.id, scenario_id:, items: items.map { item_row(it) }, names: names_of(plan, items) }
  end

  private

  # A capacity item's subject is a person or an open position, so only an
  # assignment's subject unknown here is a forgotten person.
  def names_of(plan, items)
    named = items.select { person_facet?(it.facet) }
    known = ::Person.where(tenant_id: plan.tenant_id, id: named.map(&:subject_id).uniq).pluck(:id, :name).to_h
    named.filter_map do |item|
      name = known.fetch(item.subject_id) { Person::FORMER_MEMBER if item.facet == ::TeamPlanning::Attention::ASSIGNMENT }
      [ item.subject_id, name ] if name
    end.to_h
  end

  def person_facet?(facet) = facet == ::TeamPlanning::Attention::ASSIGNMENT || facet.split(":").first == ::TeamPlanning::Attention::CAPACITY

  def item_row(item)
    change = item.change && { kind: item.change.class.name.demodulize, scenario_id: item.change.data[:scenario_id],
                              event_id: item.change.event_id }
    { subject_id: item.subject_id, facet: item.facet, reason: item.reason, change: }
  end
end
