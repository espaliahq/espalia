# frozen_string_literal: true

# Proposes deleting a framework entity — a capability (archive) or a role
# illustration (removal) — as a pending suggestion for review.
#
# Always lands **pending** (there is no editing mode here): the direct-apply
# path is the archive tools (frameworks_archive_capability /
# frameworks_archive_illustration), which decide direct-vs-suggest from the
# author's authority. This tool is the explicit "propose for review" surface,
# mirroring the web's propose-a-change endpoint. On approval the reviewer's
# action runs the same archive/remove command.
#
# Only entity types with a destructive command are accepted — the aggregate
# has no delete for roles/levels/families (those are org-restructures).
#
# Write — :mcp_client (a pending proposal; nothing is removed until a
# reviewer approves, and a capability archive is still draft-gated after that).
class Operations::Frameworks::SuggestDelete < Operations::Base
  description "Propose deleting a framework entity (capability or example) as a pending suggestion — nothing is removed until a reviewer approves."
  category :write
  approval :mcp_client
  prose_fields :rationale

  parameter :framework_id, String, required: true
  parameter :entity_type,  String, required: true,
                                   allowed: Frameworks::Aggregate::DELETABLE_ENTITY_TYPES
  parameter :entity_id,    String, required: true
  parameter :rationale,    String

  def policy_check
    authorize framework, :submit_suggestion?
  end

  # @return [Hash] { framework_id:, entity_type:, entity_id:, suggestion_id:, status: }
  def perform
    require_author!
    ensure_entity_exists!
    ensure_no_pending_deletion!

    suggestion_id = SecureRandom.uuid_v7
    Frameworks::CommandHandler.new.suggest_delete(
      framework.framework_id, suggestion_id,
      params[:entity_type], params[:entity_id],
      author_id: author_id,
      rationale: params[:rationale].presence,
      mode: :suggesting
    )

    {
      framework_id: framework.framework_id,
      entity_type: params[:entity_type],
      entity_id: params[:entity_id],
      suggestion_id: suggestion_id,
      status: "pending"
    }
  end

  private

  # Resolve from the explorer graph so a draft-added capability is proposable
  # (Lesson 17) and the id is scoped to the authorized framework.
  def ensure_entity_exists!
    capabilities = explorer_graph.capability_categories.flat_map(&:capabilities)
    ids =
      if params[:entity_type] == "capability"
        capabilities.map(&:capability_id)
      else
        capabilities.flat_map(&:expectations).flat_map(&:illustrations).map(&:illustration_id)
      end

    return if ids.include?(params[:entity_id])

    raise ActiveRecord::RecordNotFound,
          "#{Frameworks::EntityLabels.for(params[:entity_type])} #{params[:entity_id]} not found in this framework"
  end

  # One pending deletion per author per entity (the aggregate enforces the
  # same rule) — pre-check so a repeat reads as invalid params, not an
  # internal error (mcp-server.md Lesson 13).
  def ensure_no_pending_deletion!
    return unless FrameworkState::SuggestedEdit.pending.deletes
                    .for_entity(params[:entity_type], params[:entity_id])
                    .where(framework_id: framework.framework_id, author_id: author_id)
                    .exists?

    raise Operations::Base::ParameterError,
          "You have already proposed deleting this #{Frameworks::EntityLabels.humanized(params[:entity_type])}"
  end

  def author_id
    context.person&.id&.to_s
  end

  def require_author!
    return if author_id.present?

    raise Operations::Base::ParameterError,
          "Proposing a deletion requires a linked person; this account has none."
  end

  def explorer_graph
    @explorer_graph ||= Frameworks::ExplorerGraph.load(framework.framework_id) ||
                        Frameworks::ExplorerGraph.rebuild(framework.framework_id)
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
