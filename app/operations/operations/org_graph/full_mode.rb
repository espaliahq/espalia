# frozen_string_literal: true

# Full mode on the Org Graph's history reads names each person's facts and
# memberships, so only those who may change the structure read it. Summary
# stays open to every member.
module Operations::OrgGraph::FullMode
  REFUSAL = "Full mode is open to tenant admins and Org Graph editors."

  private

  # @raise [Pundit::NotAuthorizedError] when full mode is asked for by
  #   someone who may not change the structure
  def authorize_full_mode
    return unless params[:mode] == "full"
    return if Pundit.policy!(context, :org_graph).edit_structure?

    raise Pundit::NotAuthorizedError, REFUSAL
  end
end
