# frozen_string_literal: true

# Updates a role's editorial details — name, short code, and/or track.
# Shape-preserving (a role's name/code/track doesn't alter the rating grid), so
# it applies live regardless of draft state.
#
# Org-structure edits are direct (not the suggested-edit path that capability /
# category text uses): gated by FrameworkPolicy#update_role? — the edit-rights
# bar (owner / editor / leads or tenant admin).
#
# Write — :mcp_client.
class Operations::Frameworks::UpdateRole < Operations::Base
  description "Update a role's name, code, or track (owner/editor/lead only)."
  category :write
  approval :mcp_client

  parameter :framework_id, String, required: true
  parameter :role_id,      String, required: true
  parameter :name,         String, allow_blank: false
  parameter :code,         String, allow_blank: false
  parameter :track,        String, allowed: %w[ic management]
  requires_any_of :name, :code, :track

  def policy_check
    authorize framework, :update_role?
  end

  # @return [Hash] { framework_id:, role_id:, name: }
  def perform
    Frameworks::CommandHandler.new.update_role(
      framework.framework_id, params[:role_id],
      name: params[:name].presence, code: params[:code].presence, track: params[:track].presence
    )
    { framework_id: framework.framework_id, role_id: params[:role_id], name: params[:name] }
  end

  private

  # At least one updatable field must be supplied (blank values are ignored —
  # the aggregate compacts nils, so a blank field is a no-op for that attribute).
  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
