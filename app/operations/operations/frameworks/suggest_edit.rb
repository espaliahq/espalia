# frozen_string_literal: true

# Edits a framework content field — capability / category name or description,
# behavioural-expectation text, or illustration text — through the shared
# suggest/approve path the web's inline editors use.
#
# In **editing** mode (the default) an author with approval authority over the
# entity's review tier has the edit applied immediately (auto-approved); in
# **suggesting** mode, or without authority, it lands as a pending suggestion
# rendered as an inline diff in the explorer. When the author already has a
# pending edit on the same (entity, field), the new value AMENDS it instead of
# stacking a second suggestion — one pending proposal per author per field,
# exactly like the web (see framework-explorer.md, "Editing vs Suggesting").
#
# Org-structure renames (role family / role / level) are NOT edited here —
# they are direct edits with their own Update* Operations (no approval tier).
#
# Write — :mcp_client. Restricted to suggest-rights holders
# (FrameworkPolicy#suggest_edit?); the direct-apply decision is the
# aggregate's `can_approve?`, driven by the mode + the author's authority.
class Operations::Frameworks::SuggestEdit < Operations::Base
  description "Edit framework content (capability/category name or description, expectation or example text) — applied directly with approval rights in editing mode, else proposed as a suggestion; consecutive edits amend your pending proposal."
  category :write
  approval :mcp_client

  # The content entity types the suggest/approve path covers, and the fields
  # each exposes. Matches the web's four inline-edit surfaces.
  EDITABLE_FIELDS = {
    "capability"              => %w[name description],
    "capability_category"     => %w[name description],
    "behavioural_expectation" => %w[description],
    "role_illustration"       => %w[description]
  }.freeze

  parameter :framework_id, String, required: true
  parameter :entity_type,  String, required: true, allowed: EDITABLE_FIELDS.keys
  parameter :entity_id,    String, required: true
  parameter :field,        String, required: true, allowed: %w[name description]
  parameter :value,        String, required: true
  parameter :rationale,    String
  parameter :mode,         String, allowed: %w[editing suggesting]

  def policy_check
    authorize framework, :suggest_edit?
  end

  # @return [Hash] { framework_id:, entity_type:, entity_id:, field:, suggestion_id:, applied:, amended: }
  def perform
    validate_field!
    validate_value!
    require_author!
    ensure_entity_exists!

    # Amend the author's own pending edit on this (entity, field) rather than
    # stacking a second suggestion (one pending proposal per author per field).
    if (existing = author_pending_edit)
      Frameworks::CommandHandler.new.amend_suggestion(
        framework.framework_id, existing.suggestion_id, params[:value], author_id,
        rationale: params[:rationale].presence
      )
      return result(suggestion_id: existing.suggestion_id, applied: false, amended: true)
    end

    suggestion_id = SecureRandom.uuid_v7
    Frameworks::CommandHandler.new.suggest_edit(
      framework.framework_id, suggestion_id,
      params[:entity_type], params[:entity_id],
      params[:field], params[:value], author_id,
      rationale: params[:rationale].presence, mode: mode_sym
    )

    result(suggestion_id: suggestion_id, applied: applied?(suggestion_id), amended: false)
  end

  private

  def result(suggestion_id:, applied:, amended:)
    {
      framework_id: framework.framework_id,
      entity_type: params[:entity_type],
      entity_id: params[:entity_id],
      field: params[:field],
      suggestion_id: suggestion_id,
      applied: applied,
      amended: amended
    }
  end

  # Whether the fresh suggestion was auto-approved (authority in editing mode).
  # The projection is synchronous, so the read-model row reflects it at once.
  def applied?(suggestion_id)
    FrameworkState::SuggestedEdit.find_by(suggestion_id: suggestion_id)&.status == "approved"
  end

  # The author's own pending edit on this exact (entity, field), if any.
  def author_pending_edit
    FrameworkState::SuggestedEdit
      .pending.edits
      .for_entity(params[:entity_type], params[:entity_id])
      .where(framework_id: framework.framework_id, field: params[:field], author_id: author_id)
      .order(created_at: :desc)
      .first
  end

  # mode defaults to editing when unset (e.g. MCP) so authority alone decides —
  # the same default the web's editing/suggesting toggle has.
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
          "Editing framework content requires a linked person; this account has none."
  end

  def validate_field!
    return if EDITABLE_FIELDS.fetch(params[:entity_type]).include?(params[:field])

    raise Operations::Base::ParameterError,
          "#{Frameworks::EntityLabels.for(params[:entity_type])} has no editable #{params[:field]} field"
  end

  # A suggested value can never be blank — the SuggestedEdit read model
  # enforces presence for edit-kind suggestions, so a blank would surface as
  # an internal error instead of invalid params.
  def validate_value!
    return if params[:value].strip.present?

    raise Operations::Base::ParameterError, "value can't be blank"
  end

  # Resolve the target from the explorer graph, NOT the published read model —
  # a draft-added capability/expectation is deferred from the read model
  # (shape-changing) but must stay editable (framework-explorer.md Lesson 17).
  # The graph is per-framework, so this also scopes the id to the authorized
  # framework.
  def ensure_entity_exists!
    return if graph_entity_ids.include?(params[:entity_id])

    raise ActiveRecord::RecordNotFound,
          "#{Frameworks::EntityLabels.for(params[:entity_type])} #{params[:entity_id]} not found in this framework"
  end

  def graph_entity_ids
    categories = explorer_graph.capability_categories
    capabilities = categories.flat_map(&:capabilities)

    case params[:entity_type]
    when "capability_category"     then categories.reject { |c| c.status == "archived" }.map(&:category_id)
    when "capability"              then capabilities.map(&:capability_id)
    when "behavioural_expectation" then capabilities.flat_map(&:expectations).map(&:expectation_id)
    when "role_illustration"       then capabilities.flat_map(&:expectations).flat_map(&:illustrations).map(&:illustration_id)
    end
  end

  def explorer_graph
    @explorer_graph ||= Frameworks::ExplorerGraph.load(framework.framework_id) ||
                        Frameworks::ExplorerGraph.rebuild(framework.framework_id)
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
