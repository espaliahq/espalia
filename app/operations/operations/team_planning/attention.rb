# frozen_string_literal: true

# What no longer fits in a scenario, from {TeamPlanning::Attention.for}
# [#257](https://github.com/espaliahq/espalia/issues/257). An item names its
# subject, a person among them, so the forgotten-person audit walks it.
class Operations::TeamPlanning::Attention < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "List what needs attention in a scenario of a Team Planning plan the caller is in: changes that " \
              "still resolve but no longer fit, often because a scenario it follows changed later. Each item has " \
              "the subject_id and facet that no longer fit (a person's assignment, a position, a unit, a " \
              "succession, a reporting line, a budget line, a position's funding, or a place's capacity as capacity:<unit or position id>, or " \
              "capacity:#{::TeamPlanning::Attention::UNASSIGNED} for someone in no unit), a reason, and the change it belongs to: its " \
              "kind, the scenario that made it and its event_id. That is the later to land of the subject's own change and the change " \
              "that broke it, such as a parent unit's retirement; change is null when nothing in the plan explains it. " \
              "It also checks each person: placed nowhere, over or under 100% allocated (an unknown total is " \
              "neither), still in the plan after the Org Graph has them leave, no manager (except the head of the " \
              "tree), or a manager who is gone, has left, or is in or owns none of their units nor the unit directly above one. " \
              "In a plan scoped to chosen units, each change about someone the plan no longer covers is listed under that " \
              "change's facet, unnamed, because a bring-in was undone or the Org Graph moved them out; clear the change or place them back in. " \
              "Once a capacity model is chosen for any role or family, even one no place takes, each place no model covers is listed too, except a leaver's, " \
              "a forgotten person's override and a closed position's. A seat whose reports cost more to manage than it delivers, " \
              "a person or an open position, is listed once under the facet capacity, overridden or not. " \
              "`sources` names where to fix each item: the provider of employment status for someone who joined " \
              "after the base or has left, the provider of the manager fact for a manager item, else the providers " \
              "of the units the item touches (\"espalia\" for a unit only the plan holds). " \
              "Items come grouped by check, named in each item's `check`, in this order: " \
              "#{::TeamPlanning::Attention::CHECKS.join(', ')}; then " \
              "by subject_id and reason. Fix an item with a new change, or by pinning or clearing one. `names` maps each subject the " \
              "scenario's map holds to the name the map shows: a person's (a placeholder hire's label), a unit's, a position's " \
              "such as \"Backfill: Software Engineer\", or a succession's as its units before and after. A forgotten person reads as " \
              "\"#{Person::FORMER_MEMBER}\", a removed placeholder label as \"#{::TeamPlanning::Baseline::PLACEHOLDER_NAME}\", and a " \
              "unit, position or succession the map no longer holds has no name. #{UNCHECKED} Refused, as an unknown plan, unless " \
              "the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, schema: { description: "The scenario, or the plan's id for the baseline. Omit it for the baseline." }

  # @return [Hash] `{ plan_id, scenario_id, checked, items, names }`, with archived_on and note for an archived plan
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id) || plan.id
    if plan.archived?
      known_scenario!(plan, scenario_id)
      return { plan_id: plan.id, scenario_id:, **checked(plan), items: [], names: {} }
    end

    report = refusing_bad_plans { ::TeamPlanning::Attention.for(context:, plan:, scenario_id:) }
    sources = ::TeamPlanning::SourceOfTruth.new(tenant_id: plan.tenant_id).preload(unit_ids: report.items.flat_map(&:unit_ids))
    { plan_id: plan.id, scenario_id:, **checked(plan), items: report.items.map { item_row(it, sources) }, names: report.names }
  end

  private

  def item_row(item, sources)
    change = item.change && { kind: item.change.class.name.demodulize, scenario_id: item.change.data[:scenario_id],
                              event_id: item.change.event_id }
    { check: item.check.to_s, subject_id: item.subject_id, facet: item.facet, reason: item.reason, change:,
      sources: item.fact ? sources.of_fact(item.fact) : sources.of_units(item.unit_ids) }
  end
end
