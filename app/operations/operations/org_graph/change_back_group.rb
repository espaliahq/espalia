# frozen_string_literal: true

# "Change it back" for a whole group of a unit's activity (#137).
class Operations::OrgGraph::ChangeBackGroup < Operations::Base
  description "Change back every change made under one cause, by the cause_id of a group from " \
              "org_graph_activity. Reverses it in every unit it touched, not just the one read, as new " \
              "changes; history keeps both. Refused as a whole, with the reason, unless every part can " \
              "be changed back."
  category :write
  approval :mcp_client

  parameter :cause_id, String, required: true, allow_blank: false

  def policy_check
    authorize :org_graph, :show_units?
  end

  # @return [Hash] `:cause_id`, `:unit_ids` every unit it touched
  # @raise [Operations::Base::ParameterError] when the group can't be changed back
  def perform
    unit_ids = OrgUnitActivity.caused_by(params[:cause_id]).pluck(:unit_id).uniq
    ::OrgGraph::ChangeBackHandler.new(actor: context).change_back_group(params[:cause_id])
    { cause_id: params[:cause_id], unit_ids: }
  rescue RuntimeError => e
    raise ParameterError, e.message
  end
end
