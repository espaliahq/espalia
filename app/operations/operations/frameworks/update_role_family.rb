# frozen_string_literal: true

# Renames (or re-describes) a role family. Shape-preserving — a role family's
# name/description doesn't touch the rating grid, so it applies live regardless
# of draft state (no draft opened, no migration mapping).
#
# Org-structure edits are direct (not the suggested-edit path that capability /
# category text uses): gated by FrameworkPolicy#update_role_family? — the
# edit-rights bar (owner / editor / leads or tenant admin).
#
# Write — :mcp_client.
class Operations::Frameworks::UpdateRoleFamily < Operations::Base
  description "Rename or re-describe a role family (owner/editor/lead only)."
  category :write
  approval :mcp_client

  parameter :framework_id,   String, required: true
  parameter :role_family_id, String, required: true
  parameter :name,           String
  parameter :description,    String

  def policy_check
    authorize framework, :update_role_family?
  end

  # @return [Hash] { framework_id:, role_family_id:, name: }
  def perform
    require_update_field!

    Frameworks::CommandHandler.new.update_role_family(
      framework.framework_id, params[:role_family_id],
      name: params[:name].presence, description: params[:description]
    )
    { framework_id: framework.framework_id, role_family_id: params[:role_family_id], name: params[:name] }
  end

  private

  # At least one updatable field must be supplied. A blank name is treated as
  # "not supplied" (a role family can't be renamed to nothing); a supplied
  # description — including "" to clear it — counts.
  def require_update_field!
    return if params[:name].present? || !params[:description].nil?

    raise Operations::Base::ParameterError, "provide a name or description to update"
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
