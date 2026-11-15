# frozen_string_literal: true

# Changes which units a plan covers
# [#338](https://github.com/espaliahq/espalia/issues/338). Widening is always
# allowed. Narrowing is refused while a change is about something the
# narrower plan would leave out, since the change would go on shaping a
# figure nobody in the plan could see. The refusal names each such change
# whose subject the caller can name in the plan as it stands, and counts the
# rest, so it never names anyone the plan doesn't already show.
class Operations::TeamPlanning::SetPlanScope < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  # Changes a refusal names before it counts the rest.
  NAMED = 5

  # @return [Integer] changes a refusal names; a seam for tests
  def self.named = NAMED

  description "Set which units a Team Planning plan covers: unit_ids, each with everything under it, or none for the " \
              "whole organisation. Widening is always allowed. Narrowing is refused while the plan holds a change about a " \
              "person, unit or position the narrower plan would leave out; the refusal names those changes and counts any " \
              "it can't name. Refused unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :unit_ids, Array, required: true,
                              schema: { type: "array", items: { type: "string" }, description: "the units it covers; none for the whole organisation" }

  # @return [Hash] `{ plan_id, scope: { whole_organisation, units: [{ unit_id, name }] } }`
  def perform
    plan_id = plan_id!
    refusing_bad_plans do
      handler.set_plan_scope(plan_id, unit_ids: params[:unit_ids].to_a) { |aggregate, unit_ids| keep_every_change!(aggregate, unit_ids) }
    end
    { plan_id:, scope: Operations::TeamPlanning::Plan.scope_of(TeamPlanningPlan.find(plan_id)) }
  end

  private

  # A change is dropped when the plan holds what it is about today and the
  # narrower plan would not. One about someone the plan already leaves out
  # stays as it is, so re-saving or widening never trips on it.
  def keep_every_change!(aggregate, unit_ids)
    return if unit_ids.empty?

    current = TeamPlanningPlan.find(aggregate.plan_id)
    return if current.scope_unit_ids.present? && (current.scope_unit_ids - unit_ids).empty?

    scenario_ids = [ aggregate.plan_id, *aggregate.scenarios.keys ]
    changes = scenario_ids.flat_map { |scenario_id| aggregate.changes_in(scenario_id).map { [ scenario_id, it ] } }
    return if changes.empty?

    narrower = TeamPlanningPlan.find(aggregate.plan_id).tap { it.scope_unit_ids = unit_ids }
    now = maps(current, aggregate, scenario_ids)
    held_now = now.transform_values { held_ids(it) }
    held = maps(narrower, aggregate, scenario_ids).transform_values { held_ids(it) }
    dropped = changes.select do |scenario_id, change|
      subject_id = change.data[:subject_id]
      held_now[scenario_id].include?(subject_id) && !held[scenario_id].include?(subject_id)
    end
    return if dropped.empty?

    baseline = ::TeamPlanning::Baseline.new(context:, plan: current)
    raise ::TeamPlanning::Error, refusal(dropped, now.values.map { baseline.named(it) }, aggregate.plan_id)
  end

  # Each change is judged against its own scenario's map.
  def maps(plan, aggregate, scenario_ids)
    base = ::TeamPlanning::Baseline.new(context:, plan:).structure
    scenario_ids.index_with { ::TeamPlanning::Resolution.new(context:, plan:, scenario_id: it, base:).structure(aggregate) }
  end

  def held_ids(map)
    ((map.people + map.units + map.retired_units + map.positions + map.budget_lines + map.successions).map(&:id) +
      map.departed.map(&:person_id)).to_set
  end

  # Names each subject once and counts every change it couldn't show.
  def refusal(dropped, current, plan_id)
    names = TeamPlanningScenario.where(plan_id:).to_h { [ it.id, it.name&.reveal ] }
    described = dropped.map do |scenario_id, change|
      subject = name_in(current, change.data[:subject_id])
      "#{subject} in #{scenario_id == plan_id ? 'the baseline' : names[scenario_id] || 'a scenario'}" if subject
    end
    shown = described.compact.uniq.first(self.class.named)
    rest = described.count { !shown.include?(it) }
    listed = shown + (rest.positive? ? [ "#{rest} other #{'change'.pluralize(rest)}" ] : [])
    "The narrower plan would leave out what these changes are about: #{listed.to_sentence}. " \
      "Undo them, or keep the units they are about"
  end

  def name_in(maps, subject_id)
    maps.each do |map|
      unit = (map.units + map.retired_units).find { it.id == subject_id }
      return unit.name if unit
      return map.names[subject_id] if map.names.key?(subject_id)

      position = map.positions.find { it.id == subject_id }
      return [ position.role_name, "position" ].compact.join(" ") if position
    end
    nil
  end
end
