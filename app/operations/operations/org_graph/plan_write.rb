# frozen_string_literal: true

# The Org Graph writes a plan's change can make. Each takes the plan change
# it applies and the cause it belongs to, and hands both to the command
# handlers, which stamp them on every event (see {OrgGraph::PlanReference}).
# Prepend it, beside {Operations::OrgGraph::UnitWrite}, so it wraps the
# operation's own perform.
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

  def self.prepended(base)
    PARAMETERS.each do |name, description|
      base.parameter name, String, allow_blank: false, schema: { format: "uuid", description: description }
    end
    base.dependent_required :plan_change_id, requires: :plan_id
    base.dependent_required :cause_id, requires: :plan_id
  end

  # Applying a plan's changes takes the may-approve right, which Team
  # Planning 8.1 adds, so until then nobody may and every reference is refused.
  #
  # @param context [AuthorizationContext]
  # @param plan_id [String]
  # @return [Boolean]
  def self.may_apply?(context, plan_id) = false

  # Checks the reference in the write's own transaction, so two plans can't
  # both claim a new cause.
  def perform
    return super unless params[:plan_id]

    ActiveRecord::Base.transaction do
      @plan = plan_reference!
      super
    end
  end

  private

  def structure_handler(cause_id: nil) = super(cause_id: plan_cause_id || cause_id)

  def person_handler = super(cause_id: plan_cause_id)

  # @return [Hash] `plan_id:` and `plan_change_id:` for each command, empty for a direct edit
  def plan = @plan.to_h

  def plan_cause_id = (params[:cause_id]&.downcase if @plan)

  # @return [OrgGraph::PlanReference]
  # @raise [Operations::Base::ParameterError]
  def plan_reference!
    plan_id, plan_change_id, cause_id = PARAMETERS.keys.map { uuid!(it).downcase if params[it] }
    unless Operations::OrgGraph::PlanWrite.may_apply?(context, plan_id)
      raise Operations::Base::ParameterError, "plan_id names no plan whose changes you may apply"
    end
    shared_cause!(cause_id, plan_id) if cause_id

    ::OrgGraph::PlanReference.new(plan_id:, plan_change_id:)
  end

  # Changing a group back undoes every change in it, so a plan can't join
  # one a direct edit or another plan started. This reads the activity feed,
  # which a rebuild empties for a while and which misses events no unit
  # shows; once approval lands (8.4), the plan's stream will say which causes it owns.
  def shared_cause!(cause_id, plan_id)
    ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", "org-graph-cause:#{cause_id}" ])
    )
    return unless OrgUnitActivity.caused_by(cause_id).where("plan_id IS DISTINCT FROM ?", plan_id).exists?

    raise Operations::Base::ParameterError, "cause_id already groups changes that aren't from this plan"
  end
end
