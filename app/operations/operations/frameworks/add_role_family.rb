# frozen_string_literal: true

# Adds a role family to a framework — a grouping container that roles are then
# added into, optionally grouped under a free-text department label.
# Shape-preserving (a family with no roles changes no rating grid), so it
# applies live and opens no draft. Until one of its roles gains published
# levels, the family renders only in the edit-mode tree, as a ghost (wiggle).
#
# Write — :mcp_client. Restricted to edit-rights holders
# (FrameworkPolicy#add_role_family?).
class Operations::Frameworks::AddRoleFamily < Operations::Base
  description "Add a role family to a framework (owner/editor/lead only)."
  category :write
  approval :mcp_client

  parameter :framework_id, String, required: true
  parameter :name,         String, required: true
  parameter :description,  String
  parameter :department,   String

  def policy_check
    authorize framework, :add_role_family?
  end

  # @return [Hash] { framework_id:, role_family_id:, name:, department: }
  def perform
    role_family_id = SecureRandom.uuid_v7
    Frameworks::CommandHandler.new.add_role_family(
      framework.framework_id, role_family_id, params[:name],
      description: params[:description].presence, department: params[:department].presence
    )
    {
      framework_id: framework.framework_id, role_family_id: role_family_id,
      name: params[:name], department: params[:department].presence
    }
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
