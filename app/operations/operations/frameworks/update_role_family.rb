# frozen_string_literal: true

# Renames, re-describes, or re-groups a role family. Shape-preserving — a role
# family's name/description/department doesn't touch the rating grid, so it
# applies live regardless of draft state (no draft opened, no migration mapping).
#
# `department` is a free-text grouping label: passing a new string moves the
# family into that group (creating it if unseen), and "" clears the grouping.
#
# Org-structure edits are direct (not the suggested-edit path that capability /
# category text uses): gated by FrameworkPolicy#update_role_family? — the
# edit-rights bar (owner / editor / leads or tenant admin).
#
# Write — :mcp_client.
class Operations::Frameworks::UpdateRoleFamily < Operations::Base
  description "Update a role family's name, description, or department (owner/editor/lead only)."
  category :write
  approval :mcp_client

  parameter :framework_id,   String, required: true
  parameter :role_family_id, String, required: true
  # A family can't be renamed to nothing, but description and department are
  # legitimately cleared with "" — hence allow_blank only on the name.
  parameter :name,           String, allow_blank: false
  parameter :description,    String
  parameter :department,     String
  requires_any_of :name, :description, :department

  def policy_check
    authorize framework, :update_role_family?
  end

  # @return [Hash] { framework_id:, role_family_id:, name:, department: }
  def perform
    Frameworks::CommandHandler.new.update_role_family(
      framework.framework_id, params[:role_family_id],
      name: params[:name].presence, description: params[:description], department: params[:department]
    )
    {
      # Mirror the sanitised name the command actually applied (a blank name is
      # treated as unchanged), so the result doesn't misreport name: "".
      framework_id: framework.framework_id, role_family_id: params[:role_family_id],
      name: params[:name].presence, department: params[:department]
    }
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
