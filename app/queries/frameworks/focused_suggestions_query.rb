# frozen_string_literal: true

# Filters pending suggested edits for a framework by a focus scope and
# optional role selection. Used by the framework explorer's context pane
# to narrow the suggestion list to the currently focused matrix context.
#
# Focus levels:
# - :framework  — all pending suggestions (default)
# - :category   — scoped to one capability category (and its descendants)
# - :capability — scoped to one capability (and its expectations/illustrations)
# - :cell       — scoped to a single capability × level (one expectation +
#                 its illustrations)
#
# Role filter (optional) narrows only role_illustration rows by the
# illustration's role_id (edit/delete) or the proposed role_id (create).
# Higher-level entity types are unaffected by role filtering.
#
# @example
#   Frameworks::FocusedSuggestionsQuery.new(
#     framework: framework, focus: :capability,
#     capability_id: "uuid", role_ids: ["role-uuid"]
#   ).call
#
class Frameworks::FocusedSuggestionsQuery
  FOCUS_LEVELS = %i[framework category capability cell].freeze
  LEAF_ENTITY_TYPES = %w[capability_category capability behavioural_expectation role_illustration].freeze

  # @param framework [FrameworkState::Framework]
  # @param focus [Symbol] one of FOCUS_LEVELS
  # @param category_id [String, nil]
  # @param capability_id [String, nil]
  # @param level_ordinal [Integer, nil]
  # @param role_ids [Array<String>]
  def initialize(framework:, focus: :framework, category_id: nil,
                 capability_id: nil, level_ordinal: nil, role_ids: [])
    @framework = framework
    @focus = resolve_focus(focus, category_id: category_id,
                                   capability_id: capability_id,
                                   level_ordinal: level_ordinal)
    @category_id = category_id
    @capability_id = capability_id
    @level_ordinal = level_ordinal
    @role_ids = Array(role_ids).compact_blank
  end

  # @return [Array<FrameworkState::SuggestedEdit>] pending, newest first
  def call
    build_scope_sets

    suggestions = @framework.suggested_edits.pending.order(created_at: :desc).to_a
    suggestions.select { |s| match?(s) }
  end

  # Human-readable descriptor for the panel header.
  #
  # @return [Hash] { level:, category_name:, capability_name:, level_label: }
  def descriptor
    case @focus
    when :category
      { level: :category, category_name: focused_category&.name }
    when :capability
      {
        level: :capability,
        category_name: focused_capability&.category&.name,
        capability_name: focused_capability&.name
      }
    when :cell
      {
        level: :cell,
        category_name: focused_capability&.category&.name,
        capability_name: focused_capability&.name,
        level_label: "L#{@level_ordinal}"
      }
    else
      { level: :framework }
    end
  end

  # Builds a lookup of human-readable context for each suggestion.
  # Used by the panel view to show role name and level for each row.
  #
  # @param suggestions [Array<FrameworkState::SuggestedEdit>]
  # @return [Hash{String => String}] suggestion_id => label (e.g. "Product Designer · Level 2")
  def context_labels(suggestions)
    build_scope_sets
    build_role_lookup

    suggestions.each_with_object({}) do |s, h|
      label = context_label_for(s)
      h[s.suggestion_id] = label if label
    end
  end

  # @return [Symbol] effective focus after validation
  attr_reader :focus

  private

  # Falls back to :framework if focus requires ids that aren't provided.
  #
  # @return [Symbol]
  def resolve_focus(focus, category_id:, capability_id:, level_ordinal:)
    focus = focus.to_sym if focus.respond_to?(:to_sym)
    return :framework unless FOCUS_LEVELS.include?(focus)

    case focus
    when :category   then category_id.present?   ? :category   : :framework
    when :capability then capability_id.present? ? :capability : :framework
    when :cell
      capability_id.present? && level_ordinal.present? ? :cell : :framework
    else focus
    end
  end

  def build_scope_sets
    categories = preloaded_categories

    case @focus
    when :framework
      category_ids_set = Set.new(categories.map(&:category_id))
      capabilities = categories.flat_map(&:capabilities)
    when :category
      scoped_categories = categories.select { |c| c.category_id == @category_id }
      category_ids_set = Set.new(scoped_categories.map(&:category_id))
      capabilities = scoped_categories.flat_map(&:capabilities)
    when :capability
      capability = find_capability(categories, @capability_id)
      category_ids_set = Set.new([ capability&.category_id ].compact)
      capabilities = [ capability ].compact
    when :cell
      capability = find_capability(categories, @capability_id)
      category_ids_set = Set.new([ capability&.category_id ].compact)
      capabilities = [ capability ].compact
    end

    expectations = capabilities.flat_map(&:expectations)
    if @focus == :cell
      expectations = expectations.select { |e| e.level_ordinal == @level_ordinal }
    end
    illustrations = expectations.flat_map(&:illustrations)

    @category_ids_set     = category_ids_set
    @capability_ids_set   = Set.new(capabilities.map(&:capability_id))
    @expectation_ids_set  = Set.new(expectations.map(&:expectation_id))
    @illustration_ids_set = Set.new(illustrations.map(&:illustration_id))
    @illustration_role_ids = illustrations.each_with_object({}) do |ill, h|
      h[ill.illustration_id] = ill.role_id
    end
  end

  def match?(suggestion)
    case suggestion.target_entity_type
    when "capability_category"
      category_scope_match?(suggestion)
    when "capability"
      capability_scope_match?(suggestion)
    when "behavioural_expectation"
      expectation_scope_match?(suggestion)
    when "role_illustration"
      illustration_in_scope?(suggestion) && role_filter_matches?(suggestion)
    else
      # role, role_family, level — only visible at framework focus
      @focus == :framework
    end
  end

  # capability_category creates have nil target_entity_id (parent is framework).
  # Show creates only at framework focus.
  def category_scope_match?(suggestion)
    return false unless %i[framework category].include?(@focus)
    return @focus == :framework if suggestion.kind == "create"

    @category_ids_set.include?(suggestion.target_entity_id)
  end

  # capability creates carry parent_id = category_id.
  # Edit/delete carry target_entity_id = capability_id.
  def capability_scope_match?(suggestion)
    if suggestion.kind == "create"
      @category_ids_set.include?(suggestion.parent_id)
    else
      @capability_ids_set.include?(suggestion.target_entity_id)
    end
  end

  # behavioural_expectation creates carry parent_id = capability_id.
  # Edit/delete carry target_entity_id = expectation_id.
  def expectation_scope_match?(suggestion)
    if suggestion.kind == "create"
      @capability_ids_set.include?(suggestion.parent_id)
    else
      @expectation_ids_set.include?(suggestion.target_entity_id)
    end
  end

  def illustration_in_scope?(suggestion)
    case suggestion.kind
    when "create"
      @expectation_ids_set.include?(suggestion.parent_id)
    else
      @illustration_ids_set.include?(suggestion.target_entity_id)
    end
  end

  def role_filter_matches?(suggestion)
    return true if @role_ids.empty?

    case suggestion.kind
    when "create"
      role_id = suggestion.proposed_attributes&.dig("role_id")
      @role_ids.include?(role_id)
    else
      role_id = @illustration_role_ids[suggestion.target_entity_id]
      @role_ids.include?(role_id)
    end
  end

  def preloaded_categories
    @preloaded_categories ||= @framework.capability_categories
      .includes(capabilities: { expectations: :illustrations }).to_a
  end

  def find_capability(categories, capability_id)
    categories.flat_map(&:capabilities).find { |c| c.capability_id == capability_id }
  end

  def focused_category
    preloaded_categories.find { |c| c.category_id == @category_id }
  end

  def focused_capability
    find_capability(preloaded_categories, @capability_id)
  end

  # ── Context label helpers ──

  def build_role_lookup
    return if @role_lookup

    roles = @framework.role_families.includes(roles: :levels).flat_map(&:roles)
    @role_lookup = roles.index_by(&:role_id)
    @capability_lookup = preloaded_categories
      .flat_map(&:capabilities)
      .index_by(&:capability_id)
    @expectation_lookup = preloaded_categories
      .flat_map(&:capabilities)
      .flat_map(&:expectations)
      .index_by(&:expectation_id)
  end

  # @return [String, nil]
  def context_label_for(suggestion)
    case suggestion.target_entity_type
    when "role_illustration"  then illustration_context_label(suggestion)
    when "behavioural_expectation" then expectation_context_label(suggestion)
    when "capability"         then capability_context_label(suggestion)
    when "capability_category" then category_context_label(suggestion)
    end
  end

  # Illustration: "Role Name · Level Title" (e.g. "Software Engineer · Engineer II").
  # Both pieces are needed — the level title alone may not include the role name,
  # and the role name alone doesn't identify the seniority band.
  def illustration_context_label(suggestion)
    role_id = resolve_illustration_role_id(suggestion)
    expectation_id = resolve_illustration_expectation_id(suggestion)
    role = @role_lookup[role_id]
    expectation = @expectation_lookup[expectation_id] if expectation_id

    level = nil
    if expectation && role
      level = role.levels.find { |l| l.ordinal == expectation.level_ordinal }
    end

    if role && level
      "#{role.name} \u00b7 #{level.title}"
    elsif role
      "#{role.name} \u00b7 Level #{expectation&.level_ordinal || '?'}"
    end
  end

  # Expectation: "Capability Name · Level N"
  def expectation_context_label(suggestion)
    if suggestion.kind == "create"
      ordinal = suggestion.proposed_attributes&.dig("level_ordinal")
      cap_id = suggestion.parent_id
    else
      exp = @expectation_lookup[suggestion.target_entity_id]
      return nil unless exp

      ordinal = exp.level_ordinal
      cap_id = exp.capability_id
    end

    capability = @capability_lookup[cap_id]
    parts = [ capability&.name, ("Level #{ordinal}" if ordinal) ].compact
    parts.any? ? parts.join(" \u00b7 ") : nil
  end

  # Capability: "Capability name" or "Capability description".
  # The entity name is in the preview already, so just indicate what field.
  def capability_context_label(suggestion)
    return nil if suggestion.kind == "create"

    field = suggestion.field
    "Capability #{field}" if field.present?
  end

  # Category: "Category name" or "Category description".
  def category_context_label(suggestion)
    return nil if suggestion.kind == "create"

    field = suggestion.field
    "Category #{field}" if field.present?
  end

  def resolve_illustration_role_id(suggestion)
    if suggestion.kind == "create"
      suggestion.proposed_attributes&.dig("role_id")
    else
      @illustration_role_ids[suggestion.target_entity_id]
    end
  end

  def resolve_illustration_expectation_id(suggestion)
    if suggestion.kind == "create"
      suggestion.parent_id
    else
      preloaded_categories
        .flat_map(&:capabilities)
        .flat_map(&:expectations)
        .flat_map(&:illustrations)
        .find { |i| i.illustration_id == suggestion.target_entity_id }
        &.expectation_id
    end
  end
end
