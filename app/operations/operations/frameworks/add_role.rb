# frozen_string_literal: true

# Adds a role to a role family. Shape-preserving — a role has no rating grid
# until it gains levels, and levels are draft-born (shape-changing) — so it
# applies live and opens no draft. Until publish the new role renders only in
# the edit-mode tree, as a ghost (wiggle); the view-mode tree and matrix ignore
# it, so the published view stays clean.
#
# Write — :mcp_client. Restricted to edit-rights holders
# (FrameworkPolicy#add_role?).
class Operations::Frameworks::AddRole < Operations::Base
  description "Add a role to a role family (owner/editor/lead only)."
  category :write
  approval :mcp_client

  parameter :framework_id,   String, required: true
  parameter :role_family_id, String, required: true
  parameter :name,           String, required: true
  parameter :code,           String, required: true
  parameter :track,          String, required: true, allowed: %w[ic management]

  def policy_check
    authorize framework, :add_role?
  end

  # @return [Hash] { framework_id:, role_family_id:, role_id:, name: }
  def perform
    ensure_role_family!

    role_id = SecureRandom.uuid_v7
    Frameworks::CommandHandler.new.add_role(
      framework.framework_id, role_id, params[:role_family_id],
      params[:name], params[:code], params[:track]
    )
    {
      framework_id: framework.framework_id, role_family_id: params[:role_family_id],
      role_id: role_id, name: params[:name]
    }
  end

  private

  # Fail as invalid-params (not the aggregate's opaque RuntimeError) when the
  # family isn't part of the authorized framework — also scopes the lookup so a
  # family id from another framework can't be targeted (mcp-server.md Lesson 5).
  def ensure_role_family!
    found = FrameworkState::RoleFamily.exists?(
      framework_id: framework.framework_id, role_family_id: params[:role_family_id]
    )
    raise Operations::Base::ParameterError, "role_family_id not found in this framework" unless found
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
