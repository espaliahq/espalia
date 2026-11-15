# frozen_string_literal: true

# What no longer fits in a scenario, from {TeamPlanning::Resolution#attention}
# [#257](https://github.com/espaliahq/espalia/issues/257). An item on a person
# names them, so the forgotten-person audit walks it.
class Operations::TeamPlanning::Attention < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "List what needs attention in a scenario of a Team Planning plan the caller is in: changes that " \
              "still resolve but no longer fit, often because a scenario it follows changed later. Each item has " \
              "the subject_id and facet that no longer fit (a person's assignment, a position, a unit, a " \
              "succession, a reporting line, a budget line, or a place's capacity as capacity:<unit or position id>, or " \
              "capacity:#{::TeamPlanning::Attention::UNASSIGNED} for someone in no unit), a reason, and the change it belongs to: its " \
              "kind, the scenario that made it and its event_id. That is the later to land of the subject's own change and the change " \
              "that broke it, such as a parent unit's retirement; change is null when nothing in the plan explains it. " \
              "It also checks each person: placed nowhere, over or under 100% allocated (an unknown total is " \
              "neither), still in the plan after the Org Graph has them leave, no manager (except the head of the " \
              "tree), or a manager who is gone, has left, or is in or owns none of their units nor the unit directly above one. " \
              "Once a capacity model is chosen for any role or family, even one no place takes, each place no model covers is listed too, except a leaver's, " \
              "a forgotten person's override and a closed position's. " \
              "`sources` names where to fix each item: the provider of employment status for someone who joined " \
              "after the base or has left, the provider of the manager fact for a manager item, else the providers " \
              "of the units the item touches (\"espalia\" for a unit only the plan holds). " \
              "Items come grouped by check, in a fixed order, then " \
              "by subject_id and reason. Fix an item with a new change, or by pinning or clearing one. `names` maps each person id to a " \
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
    sources = ::TeamPlanning::SourceOfTruth.new(tenant_id: plan.tenant_id).preload(unit_ids: items.flat_map(&:unit_ids))
    { plan_id: plan.id, scenario_id:, items: items.map { item_row(it, sources) }, names: names_of(plan, items) }
  end

  PERSON_FACETS = [ ::TeamPlanning::Attention::ASSIGNMENT, ::TeamPlanning::Attention::LINE ].freeze

  private

  # A capacity item's subject is a person or an open position, so only an
  # assignment's or a line's subject unknown here is a forgotten person.
  def names_of(plan, items)
    named = items.select { person_facet?(it.facet) }
    known = ::Person.where(tenant_id: plan.tenant_id, id: named.map(&:subject_id).uniq).pluck(:id, :name).to_h
    named.filter_map do |item|
      name = known.fetch(item.subject_id) { Person::FORMER_MEMBER if PERSON_FACETS.include?(item.facet) }
      [ item.subject_id, name ] if name
    end.to_h
  end

  def person_facet?(facet) = PERSON_FACETS.include?(facet) || facet.split(":").first == ::TeamPlanning::Attention::CAPACITY

  def item_row(item, sources)
    change = item.change && { kind: item.change.class.name.demodulize, scenario_id: item.change.data[:scenario_id],
                              event_id: item.change.event_id }
    { subject_id: item.subject_id, facet: item.facet, reason: item.reason, change:,
      sources: item.fact ? sources.of_fact(item.fact) : sources.of_units(item.unit_ids) }
  end
end
