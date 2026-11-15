# frozen_string_literal: true

# What the tools that set a scenario change share: the write, with the tool's
# own checks run under the plan's lock once the caller may edit it, and the
# change already winning for a subject there. Each also takes a `note`, why
# the change is in the plan, sealed under its subject's key
# [#273](https://github.com/espaliahq/espalia/issues/273).
module Operations::TeamPlanning::ChangeWrite
  extend ActiveSupport::Concern
  include Operations::TeamPlanning::PlanWrite

  included do
    parameter :note, String, schema: {
      description: "Why this is in the plan, such as the business reason for a move. Optional, at most " \
                   "#{::TeamPlanning::PlanAggregate::NOTE_LIMIT} characters; it never changes what the scenario " \
                   "resolves to. A note on a change to a person goes when they are forgotten. Any other note, such as one " \
                   "on a unit, a position or a rule, stays until the plan is deleted, so keep personal details out of it."
    }
    prose_fields :note
  end

  private

  # @param kind [Class<TeamPlanning::Events::Change>]
  # @yieldparam plan [TeamPlanning::PlanAggregate] for the tool's own checks, under the lock
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [Operations::Base::ParameterError] "No such plan" before any check, unless the caller edits it
  def set_change!(kind, subject_id:, end_state: {}, &check)
    refusing_bad_plans do
      handler.set_change(plan_id!, kind, scenario_id: scenario_id!(:scenario_id), subject_id:, end_state:, note: params[:note]) do |plan|
        check&.call(plan)
        within_scope!(plan, kind, subject_id, end_state)
      end
    end
  end

  # A scoped plan holds changes about the people it covers, and about someone
  # outside only through the change that places them in a covered unit
  # ([#338](https://github.com/espaliahq/espalia/issues/338)). The refusal
  # says nothing about the person the plan can't show.
  def within_scope!(plan, kind, subject_id, end_state)
    record = TeamPlanningPlan.find(plan.plan_id)
    return if record.scope_unit_ids.blank?

    map = ::TeamPlanning::Resolution.new(context:, plan: record, scenario_id: scenario_id!(:scenario_id)).structure(plan)
    return unless map.outside_ids.include?(subject_id)
    return if kind == ::TeamPlanning::Events::AssignmentSet && brings_in?(map, end_state)

    raise Operations::Base::ParameterError, "This person is outside the units this plan covers. Place them in one of its units first."
  end

  def brings_in?(map, end_state)
    positions = map.positions.to_set(&:id)
    units = map.known_unit_ids
    Array(end_state[:placements]).any? do |placement|
      placement = placement.to_h.symbolize_keys
      units.include?(placement[:unit_id]) || positions.include?(placement[:position_id])
    end
  end

  # @return [TeamPlanning::Events::Change, nil] the change the scenario resolves to for this subject and facet
  def winning_change(plan, subject_id, facet) = plan.winning_changes(scenario_id!(:scenario_id))[[ subject_id, facet ]]
end
