# frozen_string_literal: true

# Renames a framework. Shape-preserving — the name doesn't touch the rating
# grid, so it applies live regardless of draft state (no draft opened, no
# migration mapping) and lands on every surface that reads it: the explorer
# header, the frameworks index, cycle and assessment pages, and the MCP
# framework payloads.
#
# A direct edit (not the suggested-edit path), gated by FrameworkPolicy#rename?
# — tenant admin or framework OWNER. Narrower than the org-structure renames'
# edit-rights bar because the name is the framework's identity, not content an
# editor curates. An unchanged name is a no-op (no event, no feed entry).
#
# Write — :mcp_client (reversible, changes no permissions).
class Operations::Frameworks::Rename < Operations::Base
  description "Rename a framework (tenant admin or framework owner only)."
  category :write
  approval :mcp_client

  parameter :framework_id, String, required: true
  parameter :name,         String, required: true, allow_blank: false

  def policy_check
    authorize framework, :rename?
  end

  # @return [Hash] { framework_id:, name: } — the name as applied (stripped)
  def perform
    Frameworks::CommandHandler.new.rename_framework(framework.framework_id, params[:name])
    { framework_id: framework.framework_id, name: framework.reload.name }
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
