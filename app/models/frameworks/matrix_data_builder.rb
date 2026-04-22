# frozen_string_literal: true

# Transforms eager-loaded framework read model data into a structured hash
# for the capability × level matrix view.
#
# Operates entirely on in-memory associations — no additional queries.
# The controller provides eager-loaded role_families (with roles + levels)
# and categories (with capabilities, bindings, expectations, illustrations).
#
# @example
#   data = Frameworks::MatrixDataBuilder.new(
#     framework: framework,
#     role_families: role_families,
#     categories: categories,
#     selected_role_ids: ["uuid1", "uuid2"],
#     track_filter: "both"
#   ).build
#
class Frameworks::MatrixDataBuilder
  # @param framework [FrameworkState::Framework, Frameworks::ExplorerGraph::Framework]
  # @param role_families [Array] role families with roles + levels; may be ExplorerGraph values or AR records
  # @param categories [Array] categories with capabilities, bindings, expectations, illustrations
  # @param selected_role_ids [Array<String>] UUIDs of selected roles
  # @param track_filter [String] "ic", "management", or "both"
  # @param mode [Symbol] `:view` (default) hides draft-only entities matching PublishedState semantics; `:edit` includes them
  # @param pending_suggestions [Hash] pre-queried map { [entity_type, entity_id] => count } for pending edits/deletes
  # @param pending_illustration_creates [Hash] pre-queried map { parent_id => [SuggestedEdit, ...] } for pending creates
  def initialize(framework:, role_families:, categories:, selected_role_ids:, track_filter: "both",
                 mode: :view, pending_suggestions: {}, pending_illustration_creates: {})
    @framework = framework
    @role_families = role_families
    @categories = categories
    @selected_role_ids = selected_role_ids
    @track_filter = track_filter
    @mode = mode
    @pending_suggestions = pending_suggestions
    @pending_illustration_creates = pending_illustration_creates
  end

  # Builds the matrix data structure.
  #
  # @return [Hash] with keys :selected_roles, :merged_levels, :categories
  def build
    @selected_roles = resolve_selected_roles
    merged_levels = build_merged_levels(@selected_roles)
    family_role_ids = build_family_role_ids(@selected_roles)
    selected_role_id_set = @selected_roles.map(&:role_id).to_set

    {
      selected_roles: @selected_roles,
      merged_levels: merged_levels,
      categories: build_categories(merged_levels, family_role_ids, selected_role_id_set)
    }
  end

  private

  # Filters roles by selected IDs and track filter from the eager-loaded role families.
  #
  # @return [Array<FrameworkState::Role>]
  def resolve_selected_roles
    all_roles = @role_families.flat_map(&:roles)

    # Apply track filter
    filtered = case @track_filter
    when "ic" then all_roles.select { |r| r.track == "ic" }
    when "management" then all_roles.select { |r| r.track == "management" }
    else all_roles
    end

    # If no roles explicitly selected, default to all filtered roles
    if @selected_role_ids.empty?
      filtered
    else
      filtered.select { |r| @selected_role_ids.include?(r.role_id) }
    end
  end

  # Merges level ordinals across all selected roles into a sorted set.
  # Each merged level carries the role codes that map to that ordinal.
  #
  # @param selected_roles [Array<FrameworkState::Role>]
  # @return [Array<Hash>] sorted by ordinal
  def build_merged_levels(selected_roles)
    levels_by_ordinal = {}

    selected_roles.each do |role|
      role.levels.each do |level|
        next unless entity_visible?(level)

        levels_by_ordinal[level.ordinal] ||= { ordinal: level.ordinal, role_codes: [] }
        levels_by_ordinal[level.ordinal][:role_codes] << {
          role_id: role.role_id,
          role_code: role.code,
          level_code: level.code,
          level_title: level.title
        }
      end
    end

    levels_by_ordinal.values.sort_by { |l| l[:ordinal] }
  end

  # In :view mode, entities flagged `added_in_draft` (new shape-changing
  # entries inside an open draft) are hidden — matching the published
  # projection's event-deferral (ADR-16). In :edit mode, everything is
  # visible and the UI styles draft-only entries distinctly.
  #
  # AR records don't carry the flag; their `respond_to?` check short-circuits.
  def entity_visible?(entity)
    return true if @mode == :edit
    return true unless entity.respond_to?(:added_in_draft)

    !entity.added_in_draft
  end

  # Collects all role_ids belonging to the same role families as selected roles.
  # Used for dimmed capability display (same-family but not directly selected).
  #
  # @param selected_roles [Array<FrameworkState::Role>]
  # @return [Set<String>]
  def build_family_role_ids(selected_roles)
    selected_family_ids = selected_roles.map(&:role_family_id).to_set
    @role_families
      .select { |rf| selected_family_ids.include?(rf.role_family_id) }
      .flat_map { |rf| rf.roles.map(&:role_id) }
      .to_set
  end

  # Builds the category → capability → cell structure for the matrix.
  #
  # @param merged_levels [Array<Hash>]
  # @param family_role_ids [Set<String>]
  # @param selected_role_id_set [Set<String>]
  # @return [Array<Hash>]
  def build_categories(merged_levels, family_role_ids, selected_role_id_set)
    ordinals = merged_levels.map { |l| l[:ordinal] }

    @categories.filter_map do |category|
      capabilities = build_capabilities(category, ordinals, family_role_ids, selected_role_id_set)
      next if capabilities.empty?

      {
        category: category,
        capabilities: capabilities,
        pending_suggestion_count: @pending_suggestions[[ "capability_category", category.category_id ]] || 0
      }
    end
  end

  # Builds capability data for a category, filtering by role family bindings.
  #
  # @return [Array<Hash>]
  def build_capabilities(category, ordinals, family_role_ids, selected_role_id_set)
    category.capabilities
      .select { |c| c.status == "active" && entity_visible?(c) }
      .filter_map do |capability|
      visible_bindings = capability.bindings.select { |b| entity_visible?(b) }
      binding_role_ids = visible_bindings.map(&:role_id).to_set

      # Only include capabilities bound to roles in the same families
      next unless binding_role_ids.intersect?(family_role_ids)

      bound_to_selected = binding_role_ids.intersect?(selected_role_id_set)
      cells = build_cells(capability, ordinals, selected_role_id_set)

      {
        capability: capability,
        bound_to_selected: bound_to_selected,
        cells: cells,
        pending_suggestion_count: @pending_suggestions[[ "capability", capability.capability_id ]] || 0
      }
    end
  end

  # Builds the cell hash for a capability across all level ordinals.
  #
  # Each cell includes:
  # - :expectation — the BehaviouralExpectation for this capability × ordinal
  # - :illustrations_by_role — hash of role_id => sorted illustrations (selected roles only)
  # - :bound_selected_role_ids — role_ids that are selected, bound to this capability,
  #     and have a level at this ordinal (may have zero illustrations — should show add button)
  #
  # @return [Hash<Integer, Hash>] ordinal => cell data
  def build_cells(capability, ordinals, selected_role_id_set) # rubocop:disable Metrics/MethodLength
    expectations_by_ordinal = capability.expectations
      .select { |e| entity_visible?(e) }
      .index_by(&:level_ordinal)
    binding_role_ids = capability.bindings
      .select { |b| entity_visible?(b) }
      .map(&:role_id).to_set
    role_ordinals = @selected_roles.each_with_object({}) do |role, h|
      h[role.role_id] = role.levels.select { |l| entity_visible?(l) }.map(&:ordinal).to_set
    end

    ordinals.each_with_object({}) do |ordinal, cells|
      expectation = expectations_by_ordinal[ordinal]
      next unless expectation

      illustrations = expectation.illustrations
        .select { |ill| selected_role_id_set.include?(ill.role_id) }

      illustrations_by_role = illustrations
        .group_by(&:role_id)
        .transform_values { |ills| ills.sort_by(&:ordinal) }

      bound_selected_role_ids = @selected_roles
        .map(&:role_id)
        .select { |rid| binding_role_ids.include?(rid) && role_ordinals[rid]&.include?(ordinal) }

      cells[ordinal] = {
        expectation: expectation,
        illustration_count: illustrations.size,
        illustrations_by_role: illustrations_by_role,
        bound_selected_role_ids: bound_selected_role_ids,
        pending_suggestion_count: @pending_suggestions[[ "behavioural_expectation", expectation.expectation_id ]] || 0,
        illustration_pending_edits: illustration_pending_edits(illustrations),
        pending_illustration_creates: @pending_illustration_creates[expectation.expectation_id] || []
      }
    end
  end

  # Builds a hash of illustration_id => pending edit count for illustrations
  # that have pending suggestions.
  #
  # @param illustrations [Array<FrameworkState::RoleIllustration>]
  # @return [Hash<String, Integer>]
  def illustration_pending_edits(illustrations)
    illustrations.each_with_object({}) do |ill, h|
      count = @pending_suggestions[[ "role_illustration", ill.illustration_id ]]
      h[ill.illustration_id] = count if count && count > 0
    end
  end
end
