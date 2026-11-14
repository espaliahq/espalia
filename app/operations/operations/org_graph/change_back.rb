# frozen_string_literal: true

# "Change it back" for one entry of a unit's activity (#137).
class Operations::OrgGraph::ChangeBack < Operations::Base
  description "Change back one entry of an Org Graph unit's activity, by its id from org_graph_activity. " \
              "Writes the inverse as a new change; history keeps both. Refused, with the reason, for a " \
              "change the caller couldn't make, one another provider supplied, one already changed back, " \
              "one a later change has replaced, or a backdated change that moved the day someone joined " \
              "a unit earlier."
  category :write
  approval :mcp_client

  parameter :entry_id, String, required: true, allow_blank: false, schema: { format: "uuid" }

  def policy_check
    authorize :org_graph, :show_units?
  end

  # @return [Hash] `:entry_id`, `:unit_id`
  # @raise [Operations::Base::ParameterError] for an unknown entry, or one that can't be changed back
  def perform
    entry = OrgUnitActivity.find_by(id: params[:entry_id].to_s.downcase) or
      raise ParameterError, "entry_id names no activity entry"
    ::OrgGraph::ChangeBackHandler.new(actor: context).change_back(entry)
    { entry_id: entry.id, unit_id: entry.unit_id }
  rescue RuntimeError => e
    raise ParameterError, e.message
  end
end
