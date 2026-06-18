# frozen_string_literal: true

# Archives (removes) a role illustration — the illustration counterpart to
# {Operations::Frameworks::ArchiveCapability}. Whether it applies directly or
# lands as a pending suggestion is driven by the edit/suggest toggle plus the
# actor's authority, mirroring inline edits and capability archiving:
#
#   editing mode  + can approve an illustration suggestion → remove directly
#   suggesting mode, OR no approval authority               → archive suggestion
#
# Illustrations carry no ratings, so there is no migration mapping. The direct
# branch runs `remove_role_illustration` (→ RoleIllustrationRemoved); the
# suggestion branch proposes the same removal, which on approval runs the very
# same command. Illustration approval is tier 1 (any edit-role holder), so most
# editors remove directly while plain collaborators propose.
#
# Write — :mcp_client. Restricted to suggest-rights holders
# (FrameworkPolicy#suggest_edit?); the direct branch additionally requires
# illustration-tier approval authority, otherwise it falls back to a suggestion.
class Operations::Frameworks::ArchiveIllustration < Operations::Base
  description "Archive a role illustration — removed directly with approval rights in editing mode, else proposed as a suggestion."
  category :write
  approval :mcp_client

  parameter :framework_id,   String, required: true
  parameter :illustration_id, String, required: true
  parameter :reason,         String
  parameter :mode,           String, allowed: %w[editing suggesting]

  def policy_check
    authorize framework, :suggest_edit?
  end

  # @return [Hash] { framework_id:, illustration_id:, archived: }
  def perform
    archived = archive_directly?
    if archived
      Frameworks::CommandHandler.new.remove_role_illustration(
        framework.framework_id, illustration.illustration_id, reason: params[:reason]
      )
    else
      Frameworks::CommandHandler.new.suggest_delete(
        framework.framework_id, SecureRandom.uuid_v7, "role_illustration", illustration.illustration_id,
        author_id: author_id, rationale: params[:reason], mode: :suggesting
      )
    end

    { framework_id: framework.framework_id, illustration_id: illustration.illustration_id, archived: archived }
  end

  private

  # Direct removal only when the toggle is "editing" AND the actor can approve an
  # illustration-tier (tier 1) suggestion. `mode` defaults to editing when unset
  # (e.g. MCP), so authority alone decides there.
  def archive_directly?
    params[:mode].to_s != "suggesting" && approval_authority.can_approve?("role_illustration")
  end

  def approval_authority
    @approval_authority ||= Frameworks::SuggestionApprovalAuthority.for(
      framework_id: framework.framework_id,
      person: context.person,
      tenant_admin: context.user&.global_admin? || context.tenant_user&.admin? || false
    )
  end

  def author_id
    context.person&.id&.to_s
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  # The illustration's framework membership is enforced by the aggregate
  # (raise_unless_entity_exists! only knows this framework's illustrations), so
  # a tenant-scoped lookup here is safe — a mismatched id raises on dispatch.
  def illustration
    @illustration ||= FrameworkState::RoleIllustration.find_by(illustration_id: params[:illustration_id]) ||
      raise(ActiveRecord::RecordNotFound, "illustration #{params[:illustration_id]} not found")
  end
end
