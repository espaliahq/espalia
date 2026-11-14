# frozen_string_literal: true

# The Org Graph writes a plan's change can make. Each takes the plan change
# it applies and the cause it belongs to, and hands both to the command
# handlers, which stamp them on every event (see {OrgGraph::PlanReference}).
# Include it after {Operations::OrgGraph::UnitWrite}.
#
# A reference says a plan made the change, so it is refused unless the
# caller may apply that plan's changes. An unknown plan and a hidden one get
# the same answer.
module Operations::OrgGraph::PlanWrite
  PARAMETERS = {
    plan_id: "the plan whose change this applies. Refused unless you may apply that plan's changes",
    plan_change_id: "the plan change this applies; needs plan_id",
    cause_id: "groups this with the plan's other changes, to change back together; needs plan_id"
  }.freeze

  def self.included(base)
    PARAMETERS.each do |name, description|
      base.parameter name, String, allow_blank: false, schema: { format: "uuid", description: description }
    end
    base.dependent_required :plan_change_id, requires: :plan_id
    base.dependent_required :cause_id, requires: :plan_id
  end

  # No plan exists until Team Planning 1.1, and who may act for one is
  # 1.2's PlanPolicy, so for now nobody may and every reference is refused.
  #
  # @param context [AuthorizationContext]
  # @param plan_id [String]
  # @return [Boolean]
  def self.may_apply?(context, plan_id) = false

  def policy_check
    super
    plan_reference!
  end

  private

  def structure_handler(cause_id: nil) = super(cause_id: plan_cause_id || cause_id)

  def person_handler = ::OrgGraph::CommandHandler.new(actor: context, cause_id: plan_cause_id)

  # @return [Hash] `plan_id:` and `plan_change_id:` for each command, empty for a direct edit
  def plan = @plan.to_h

  def plan_cause_id = (params[:cause_id]&.downcase if @plan)

  # @raise [Operations::Base::ParameterError]
  def plan_reference!
    return unless params[:plan_id]

    plan_id, plan_change_id, cause_id = %i[plan_id plan_change_id cause_id].map { uuid!(it).downcase if params[it] }
    unless Operations::OrgGraph::PlanWrite.may_apply?(context, plan_id)
      raise Operations::Base::ParameterError, "plan_id names no plan whose changes you may apply"
    end
    # Changing a group back undoes every change in it, so a plan can't join
    # one a direct edit or another plan started.
    if cause_id && OrgUnitActivity.caused_by(cause_id).where("plan_id IS DISTINCT FROM ?", plan_id).exists?
      raise Operations::Base::ParameterError, "cause_id already groups changes that aren't from this plan"
    end

    @plan = ::OrgGraph::PlanReference.new(plan_id:, plan_change_id:)
  end
end
