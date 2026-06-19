# frozen_string_literal: true

# Authors a behavioural expectation in a previously-empty capability × level
# cell — the canonical statement people are rated against at that level. This
# fills a gap in the rating grid.
#
# Follows the same suggest/approve path as every other framework content change
# (it routes through `suggest_create`): in **editing** mode an author with
# approval authority over expectations (tier 3 — owner / editor / capability or
# category lead) has it applied immediately; in **suggesting** mode, or without
# that authority, it lands as a pending `behavioural_expectation` creation
# suggestion for review. Applying it is shape-changing (auto-opens a draft,
# deferred from the published read model until publish).
#
# Write — :mcp_client. Restricted to suggest-rights holders
# (FrameworkPolicy#suggest_edit?); the direct-apply decision is the aggregate's
# `can_approve?` (same as inline edits), driven by the edit/suggest toggle.
class Operations::Frameworks::SetBehaviouralExpectation < Operations::Base
  description "Author a behavioural expectation for an empty cell — applied directly with approval rights in editing mode, else proposed as a suggestion."
  category :write
  approval :mcp_client

  parameter :framework_id,  String,  required: true
  parameter :capability_id, String,  required: true
  parameter :level_ordinal, Integer, required: true
  parameter :description,   String,  required: true
  parameter :mode,          String,  allowed: %w[editing suggesting]

  def policy_check
    authorize framework, :suggest_edit?
  end

  # @return [Hash] { framework_id:, capability_id:, level_ordinal:, suggestion_id:, applied: }
  def perform
    validate_description!
    ensure_cell_empty!
    require_author!

    suggestion_id = SecureRandom.uuid_v7
    created_entity_id = Frameworks::CommandHandler.new.suggest_create(
      framework.framework_id, suggestion_id, "behavioural_expectation",
      { "level_ordinal" => params[:level_ordinal], "description" => params[:description] },
      parent_id: capability.capability_id, author_id: author_id, mode: mode_sym
    )

    {
      framework_id: framework.framework_id,
      capability_id: capability.capability_id,
      level_ordinal: params[:level_ordinal],
      suggestion_id: suggestion_id,
      applied: created_entity_id.present?
    }
  end

  private

  # mode defaults to editing when unset (e.g. MCP) so authority alone decides.
  def mode_sym
    params[:mode].to_s == "suggesting" ? :suggesting : :editing
  end

  def author_id
    context.person&.id&.to_s
  end

  # A suggestion (and its attribution) needs an author. suggest_edit? permits a
  # tenant_admin with no linked Person, so guard rather than create an
  # unattributed suggestion.
  def require_author!
    return if author_id.present?

    raise Operations::Base::ParameterError,
          "Authoring an expectation requires a linked person; this account has none."
  end

  def validate_description!
    return if params[:description].strip.present?

    raise Operations::Base::ParameterError, "description can't be blank"
  end

  # Guard against proposing/applying an expectation over an existing one at the
  # same cell. Checks the graph so an expectation authored earlier in the current
  # draft is also caught. (The aggregate enforces the same invariant on apply.)
  def ensure_cell_empty!
    return unless capability.expectations.any? { |e| e.level_ordinal == params[:level_ordinal] }

    raise Operations::Base::ParameterError,
          "capability #{capability.capability_id} already has an expectation at level #{params[:level_ordinal]}"
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  # Resolve from the explorer graph (incl. draft-added capabilities), which also
  # scopes the lookup to the authorized framework.
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
