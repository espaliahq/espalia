# frozen_string_literal: true

# What the plan write tools share: the plan they name and the command handler,
# which checks {PlanPolicy} against the plan as its stream has it.
module Operations::TeamPlanning::PlanWrite
  UUID_RE = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  # Keeps out callers who aren't in the tenant; the handler checks the plan itself.
  def policy_check
    authorize TeamPlanningPlan, :index?, policy_class: PlanPolicy
  end

  private

  # @return [String] the plan_id parameter, downcased
  # @raise [Operations::Base::ParameterError] unless it is a UUID
  def plan_id!
    value = params[:plan_id]
    return value.downcase if value.is_a?(String) && value.match?(UUID_RE)

    raise Operations::Base::ParameterError, "plan_id must be a UUID, got #{value.inspect}"
  end

  # Runs the block, turning the plan's own refusals into a bad-parameter error.
  def refusing_bad_plans
    yield
  rescue ::TeamPlanning::Error => e
    raise Operations::Base::ParameterError, e.message
  end

  def handler = ::TeamPlanning::CommandHandler.new(actor: context)
end
