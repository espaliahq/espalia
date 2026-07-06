# frozen_string_literal: true

# Proposes creating a new framework entity — an illustration, expectation,
# capability, category, role, role family, or level — through the suggest/
# approve path. The proposed_attributes hash carries the data the matching
# add_* command needs on approval.
#
# Defaults to **suggesting** mode (always lands pending): direct add tools
# already exist for the edit-rights path (frameworks_add_capability,
# frameworks_add_role, …), so this tool is the "propose for review" surface a
# suggest-rights collaborator uses. Passing mode: "editing" mirrors the web's
# editing toggle — an author with approval authority over the entity's tier
# has the creation applied immediately.
#
# For behavioural expectations prefer frameworks_set_behavioural_expectation —
# it additionally guards the cell is empty and amends your pending proposal on
# a repeat submit.
#
# Write — :mcp_client (a pending proposal, or a creation the author could make
# via the direct add tools anyway).
class Operations::Frameworks::SuggestCreate < Operations::Base
  description "Propose creating a framework entity (illustration, expectation, capability, category, role, role family, level) as a suggestion — pending review by default; applied directly with approval rights in editing mode."
  category :write
  approval :mcp_client

  # Accepted proposed_attributes keys per entity type — the aggregate's
  # REQUIRED_CREATION_KEYS plus each type's optional attributes. Unknown keys
  # are rejected by name (never silently dropped).
  ALLOWED_CREATION_KEYS = {
    "role_illustration"       => %i[role_id description ordinal],
    "behavioural_expectation" => %i[level_ordinal description],
    "capability"              => %i[name description],
    "capability_category"     => %i[name description ordinal],
    "role"                    => %i[name code track],
    "role_family"             => %i[name description],
    "level"                   => %i[ordinal title code is_entry]
  }.freeze

  parameter :framework_id, String, required: true
  parameter :entity_type,  String, required: true, allowed: ALLOWED_CREATION_KEYS.keys
  parameter :proposed_attributes, Hash, required: true, schema: {
    "type" => "object",
    "description" => "Attributes for the new entity. Required keys by entity_type — " \
                     "role_illustration: role_id, description · behavioural_expectation: level_ordinal, description · " \
                     "capability: name · capability_category: name · role: name, code, track · " \
                     "role_family: name · level: ordinal, title, code.",
    "properties" => {
      "name"          => { "type" => "string" },
      "description"   => { "type" => "string" },
      "title"         => { "type" => "string" },
      "code"          => { "type" => "string" },
      "track"         => { "type" => "string", "enum" => %w[ic management] },
      "role_id"       => { "type" => "string" },
      "level_ordinal" => { "type" => "integer" },
      "ordinal"       => { "type" => "integer" },
      "is_entry"      => { "type" => "boolean" }
    },
    "additionalProperties" => false
  }
  parameter :parent_id, String
  parameter :rationale, String
  parameter :mode,      String, allowed: %w[editing suggesting]

  def policy_check
    authorize framework, :submit_suggestion?
  end

  # @return [Hash] { framework_id:, entity_type:, suggestion_id:, created_entity_id:, applied: }
  def perform
    validate_proposed_attributes!
    ensure_parent_exists!
    require_author!

    suggestion_id = SecureRandom.uuid_v7
    created_entity_id = Frameworks::CommandHandler.new.suggest_create(
      framework.framework_id, suggestion_id,
      params[:entity_type], proposed_attributes,
      parent_id: params[:parent_id].presence,
      author_id: author_id,
      rationale: params[:rationale].presence,
      mode: mode_sym
    )

    {
      framework_id: framework.framework_id,
      entity_type: params[:entity_type],
      suggestion_id: suggestion_id,
      created_entity_id: created_entity_id,
      applied: created_entity_id.present?
    }
  end

  private

  def proposed_attributes
    @proposed_attributes ||= params[:proposed_attributes].to_h.transform_keys(&:to_sym)
  end

  # Validate the payload's contents without letting the aggregate raise a
  # RuntimeError through to the client as an internal error (mcp-server.md
  # Lesson 13): missing required keys and unknown keys are both the client's
  # mistake → ParameterError (-32602).
  def validate_proposed_attributes!
    allowed  = ALLOWED_CREATION_KEYS.fetch(params[:entity_type])
    required = Frameworks::Aggregate::REQUIRED_CREATION_KEYS.fetch(params[:entity_type]).map(&:to_sym)

    missing = required - proposed_attributes.keys
    unless missing.empty?
      raise Operations::Base::ParameterError,
            "proposed_attributes is missing required keys for #{params[:entity_type]}: #{missing.join(', ')}"
    end

    unknown = proposed_attributes.keys - allowed
    return if unknown.empty?

    raise Operations::Base::ParameterError,
          "proposed_attributes has unknown keys for #{params[:entity_type]}: #{unknown.join(', ')} " \
          "(accepted: #{allowed.join(', ')})"
  end

  # Framework-level entities (capability_category, role_family) take no
  # parent; everything else nests under one. Resolve from the explorer graph
  # so draft-added parents count (Lesson 17) and the id is scoped to the
  # authorized framework.
  def ensure_parent_exists!
    parent_ids = expected_parent_ids
    if parent_ids.nil?
      return if params[:parent_id].blank?

      raise Operations::Base::ParameterError,
            "#{params[:entity_type]} is framework-level and takes no parent_id"
    end

    return if parent_ids.include?(params[:parent_id])

    raise ActiveRecord::RecordNotFound,
          "parent #{params[:parent_id]} for #{params[:entity_type]} not found in this framework"
  end

  # @return [Array<String>, nil] valid parent ids for the entity type, or nil
  #   when the type is framework-level (no parent)
  def expected_parent_ids
    categories = explorer_graph.capability_categories
    capabilities = categories.flat_map(&:capabilities)

    case params[:entity_type]
    when "role_illustration"       then capabilities.flat_map(&:expectations).map(&:expectation_id)
    when "behavioural_expectation" then capabilities.map(&:capability_id)
    when "capability"              then categories.reject { |c| c.status == "archived" }.map(&:category_id)
    when "role"                    then explorer_graph.role_families.map(&:role_family_id)
    when "level"                   then explorer_graph.role_families.flat_map(&:roles).map(&:role_id)
    end
  end

  # mode defaults to suggesting — this is the "propose" tool; the direct add
  # operations cover the apply-immediately path.
  def mode_sym
    params[:mode].to_s == "editing" ? :editing : :suggesting
  end

  def author_id
    context.person&.id&.to_s
  end

  def require_author!
    return if author_id.present?

    raise Operations::Base::ParameterError,
          "Proposing a creation requires a linked person; this account has none."
  end

  def explorer_graph
    @explorer_graph ||= Frameworks::ExplorerGraph.load(framework.framework_id) ||
                        Frameworks::ExplorerGraph.rebuild(framework.framework_id)
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
