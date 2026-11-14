# frozen_string_literal: true

# What the tools that set a scenario change share: the write, with the tool's
# own checks run under the plan's lock once the caller may edit it, and the
# change already winning for a subject there. Each also takes a `note`, why
# the change is in the plan, sealed under the plan's key
# [#273](https://github.com/espaliahq/espalia/issues/273).
module Operations::TeamPlanning::ChangeWrite
  extend ActiveSupport::Concern
  include Operations::TeamPlanning::PlanWrite

  included do
    parameter :note, String, schema: {
      description: "Why this is in the plan, such as why this person moves. Optional, at most " \
                   "#{::TeamPlanning::PlanAggregate::NOTE_LIMIT} characters; it never changes what the scenario " \
                   "resolves to. Deleting the plan erases it."
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
      handler.set_change(plan_id!, kind, scenario_id: scenario_id!(:scenario_id), subject_id:, end_state:, note: params[:note], &check)
    end
  end

  # @return [TeamPlanning::Events::Change, nil] the change the scenario resolves to for this subject and facet
  def winning_change(plan, subject_id, facet) = plan.winning_changes(scenario_id!(:scenario_id))[[ subject_id, facet ]]
end
