# frozen_string_literal: true

# Archives a capability — the single removal operation. Whether it applies
# directly or lands as a pending **suggestion** is driven by the edit/suggest
# toggle plus the actor's authority, mirroring inline edits:
#
#   editing mode  + can approve a capability suggestion → archive directly
#   suggesting mode, OR no approval authority           → archive suggestion
#
# The two branches use different commands so the *direct* path stays a single
# `CapabilityArchived` event (no suggestion lifecycle to double-narrate in the
# feed); the suggestion path proposes the same archive, which on approval runs
# the very same `archive_capability` command.
#
# Migration mapping is optional in both branches: the archiver/suggester may
# record it as-we-go (when they have mapping authority); otherwise the
# owner/editor supplies & validates it at the publish-review gate. A capability
# added in the current draft has nothing to migrate, so the caller omits it.
#
# Write — :mcp_client. Restricted to suggest-rights holders
# (FrameworkPolicy#suggest_edit?); the *direct* branch additionally requires
# capability-tier approval authority, otherwise it falls back to a suggestion.
class Operations::Frameworks::ArchiveCapability < Operations::Base
  description "Archive a capability — applied directly with approval rights in editing mode, else proposed as a suggestion."
  category :write
  approval :mcp_client

  parameter :framework_id,  String, required: true
  parameter :capability_id, String, required: true
  parameter :reason,        String
  parameter :mapping_type,  String,
                            allowed: Operations::Frameworks::DefineMigrationMapping::MAPPING_TYPES
  parameter :to_stable_id,  String
  parameter :mode,          String, allowed: %w[editing suggesting]

  # A mapping is optional here (it can be deferred to the publish-review
  # gate), but one that carries ratings to a survivor names it — and one that
  # doesn't must not. Both halves come from DefineMigrationMapping's own lists,
  # since the mapping this records is dispatched straight to it.
  requires_when :to_stable_id, if: :mapping_type,
                               in: Operations::Frameworks::DefineMigrationMapping::SURVIVOR_TYPES,
                               message: Operations::Frameworks::DefineMigrationMapping::SURVIVOR_REQUIRED_MESSAGE
  forbids_when :to_stable_id, if: :mapping_type,
                              in: Operations::Frameworks::DefineMigrationMapping::NON_SURVIVOR_TYPES,
                              message: Operations::Frameworks::DefineMigrationMapping::SURVIVOR_FORBIDDEN_MESSAGE

  # Both rules above arm on mapping_type's VALUE, so neither fires when it is
  # omitted entirely — and `define_mapping` is then skipped, dropping the
  # survivor on the floor. `mapping_type` is optional here (it can be deferred
  # to publish-review), so the pairing needs saying separately.
  # DefineMigrationMapping needs no equivalent: mapping_type is required there.
  MAPPING_TYPE_REQUIRED_MESSAGE =
    "to_stable_id was supplied without a mapping_type — say how the capability evolves"

  dependent_required :to_stable_id, requires: :mapping_type,
                                    message: MAPPING_TYPE_REQUIRED_MESSAGE

  def policy_check
    authorize framework, :suggest_edit?
  end

  # @return [Hash] { framework_id:, capability_id:, stable_id:, archived:, mapping_type: }
  def perform
    archived = archive_directly?
    if archived
      handler.archive_capability(framework.framework_id, capability.capability_id, reason: params[:reason])
    else
      require_author!
      # mode: :suggesting forces a pending proposal — this operation has already
      # made the direct-vs-suggest decision (via approval_authority), so the
      # command handler must NOT re-decide and auto-approve.
      handler.suggest_delete(
        framework.framework_id, SecureRandom.uuid_v7, "capability", capability.capability_id,
        author_id: author_id, rationale: params[:reason], mode: :suggesting
      )
    end

    # Record the mapping only when one was supplied AND the actor may define it
    # (owner/editor). A lead or plain suggester can't — their mapping is deferred
    # to the publish-review gate rather than erroring the archive.
    define_mapping if params[:mapping_type].present? && can_define_mapping?

    {
      framework_id: framework.framework_id,
      capability_id: capability.capability_id,
      stable_id: capability.stable_id,
      archived: archived,
      mapping_type: params[:mapping_type]
    }
  end

  private

  def handler
    @handler ||= Frameworks::CommandHandler.new
  end

  # Direct archive only when the toggle is "editing" AND the actor can approve a
  # capability-tier suggestion (owner / editor / category-lead / capability-lead,
  # or tenant admin). Otherwise the archive is proposed for review. `mode`
  # defaults to editing when unset (e.g. MCP), so authority alone decides there.
  def archive_directly?
    params[:mode].to_s != "suggesting" && approval_authority.can_approve?("capability")
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

  # A pending suggestion must be attributable. `suggest_edit?` permits a
  # tenant_admin with no linked Person, so guard the suggestion branch —
  # otherwise the aggregate `.compact`s the nil author into an unattributed
  # suggestion (breaking the per-author dedup + "proposed by" rendering). The
  # direct-archive branch needs no author.
  def require_author!
    return if author_id.present?

    raise Operations::Base::ParameterError,
          "Proposing an archive requires a linked person; this account has none."
  end

  def can_define_mapping?
    FrameworkPolicy.new(context, framework).define_migration_mapping?
  end

  def define_mapping
    Operations::Frameworks::DefineMigrationMapping.call(
      context: context,
      params: {
        framework_id: framework.framework_id,
        from_stable_id: capability.stable_id,
        to_stable_id: params[:to_stable_id],
        mapping_type: params[:mapping_type]
      }
    )
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  # Resolve from the explorer graph (NOT the published read model) so a
  # capability added in the current draft — deferred from FrameworkState::Capability
  # but present in the graph — can still be archived. The graph is per-framework,
  # so finding the id in it scopes the lookup to the authorized framework.
  def capability
    @capability ||= explorer_graph.capability_categories.flat_map(&:capabilities)
      .find { |c| c.capability_id == params[:capability_id] } ||
      raise(ActiveRecord::RecordNotFound, "capability #{params[:capability_id]} not found in this framework")
  end

  def explorer_graph
    @explorer_graph ||= Frameworks::ExplorerGraph.load(framework.framework_id) ||
                        Frameworks::ExplorerGraph.rebuild(framework.framework_id)
  end
end
