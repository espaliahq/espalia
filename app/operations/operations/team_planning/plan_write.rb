# frozen_string_literal: true

# What the plan write tools share: the plan they name and the command handler,
# which checks {PlanPolicy} against the plan as its stream has it.
#
# To anyone outside the plan it reads as missing, so a refusal never says
# which plan ids exist
# [#192](https://github.com/espaliahq/espalia/issues/192). A missing or
# deleted plan comes back as invalid params with the reason.
module Operations::TeamPlanning::PlanWrite
  UUID_RE = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  # Keeps out callers who aren't in the tenant; the handler checks the plan itself.
  def policy_check
    authorize TeamPlanningPlan, :index?, policy_class: PlanPolicy
  end

  private

  # @return [String] the plan_id parameter, downcased
  # @raise [Operations::Base::ParameterError] unless it is a UUID
  def plan_id! = uuid!(:plan_id)

  # @param name [Symbol] a scenario id parameter
  # @return [String, nil] the parameter, downcased; nil when not given
  # @raise [Operations::Base::ParameterError] unless it is a UUID
  def scenario_id!(name) = params[name].nil? ? nil : uuid!(name)

  def uuid!(name)
    value = params[name]
    return value.downcase if value.is_a?(String) && value.match?(UUID_RE)

    raise Operations::Base::ParameterError, "#{name} must be a UUID, got #{value.inspect}"
  end

  # Runs the block, turning the plan's own refusals into a bad-parameter error.
  def refusing_bad_plans
    yield
  rescue ::TeamPlanning::FirstStepEndsTooSoon, ::TeamPlanning::PeriodInverted => e
    name = TeamPlanningScenario.find_by(id: e.scenario_id)&.name&.reveal
    raise Operations::Base::ParameterError, name.present? ? e.message_for(name) : e.message
  rescue ::TeamPlanning::Error => e
    raise Operations::Base::ParameterError, e.message
  end

  def handler = ::TeamPlanning::CommandHandler.new(actor: context)
end
