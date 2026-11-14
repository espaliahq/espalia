# frozen_string_literal: true

# What the tools that set a scenario change share: the plan, refused before
# anything else unless the caller edits it, the change already winning for a
# subject there, and the write itself.
module Operations::TeamPlanning::ChangeWrite
  include Operations::TeamPlanning::PlanWrite

  private

  # Read outside the write's lock, so checks made on it can race an edit; the
  # write itself checks the plan again.
  #
  # @return [TeamPlanning::PlanAggregate]
  # @raise [Operations::Base::ParameterError] "No such plan" unless the caller edits it
  def editable_plan!
    @editable_plan ||= ::TeamPlanning::Repository.new.load_plan(plan_id!).tap do |plan|
      raise Operations::Base::ParameterError, "No such plan" unless plan.exists? && PlanPolicy.new(context, plan).update?
    end
  end

  # @return [TeamPlanning::Events::Change, nil] the change the scenario resolves to for this subject and facet
  def winning_change(subject_id, facet)
    refusing_bad_plans { editable_plan!.winning_changes(scenario_id!(:scenario_id)) }[[ subject_id, facet ]]
  end

  # @param kind [Class<TeamPlanning::Events::Change>]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  def set_change!(kind, subject_id:, end_state: {})
    refusing_bad_plans do
      handler.set_change(plan_id!, kind, scenario_id: scenario_id!(:scenario_id), subject_id:, end_state:)
    end
  end
end
