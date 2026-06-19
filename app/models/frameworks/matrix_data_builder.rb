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
  # @param pending_suggestions [Hash] pre-queried map
  #   `{ [entity_type, entity_id] => { count:, latest_by_field: { field => desc } } }`.
  #   Each `desc` is `{ suggested_value:, suggestion_id:, created_at:, id: }` for
  #   the most recent pending `kind: "edit"` on that field — so the capability
  #   name AND description frames (and category name, expectation/illustration
  #   description) each pick their own field. Consumed by the inline-diff
  #   decoration helper; `latest_by_field` is empty when the entity has only
  #   pending deletes or no pending text edits.
  # @param pending_illustration_creates [Hash] pre-queried map { parent_id => [SuggestedEdit, ...] } for pending creates
  # @param search_query [String, nil] free-text filter applied *within* the
  #   current role scope. Matches (token-AND, case-insensitive) against each
  #   capability's category name/description, capability name/description, and
  #   the text of its visible behavioural expectations. Illustrations are
  #   deliberately excluded — they're numerous, verbose, and hidden until a
  #   row is expanded, so matching them dilutes results and produces matches
  #   the user can't see. Every surface searched here is visible in the
  #   compact matrix. Role dimming is untouched — a dimmed-but-matching
  #   capability still shows.
  def initialize(framework:, role_families:, categories:, selected_role_ids:, track_filter: "both",
                 mode: :view, pending_suggestions: {}, pending_illustration_creates: {}, search_query: nil)
    @framework = framework
    @role_families = role_families
    @categories = categories
    @selected_role_ids = selected_role_ids
    @track_filter = track_filter
    @mode = mode
    @pending_suggestions = pending_suggestions
    @pending_illustration_creates = pending_illustration_creates
    @search_query = search_query.to_s.strip.presence
    @search_tokens = @search_query.to_s.downcase.split
  end

  # Builds the matrix data structure.
  #
  # @return [Hash] with keys :selected_roles, :merged_levels, :categories,
  #   :search_query (echo, nil when not searching), :in_scope_capability_count
  #   (role-scoped, before the text filter) and :matched_capability_count
  #   (after the text filter) — the in-frame "Showing N of M" banner uses the
  #   latter two; the header stat shows :in_scope_capability_count.
  def build
    @selected_roles = resolve_selected_roles
    merged_levels = build_merged_levels(@selected_roles)
    family_role_ids = build_family_role_ids(@selected_roles)
    selected_role_id_set = @selected_roles.map(&:role_id).to_set

    @in_scope_capability_count = 0
    categories = build_categories(merged_levels, family_role_ids, selected_role_id_set)

    {
      selected_roles: @selected_roles,
      merged_levels: merged_levels,
      categories: categories,
      track_filter: @track_filter,
      search_query: @search_query,
      in_scope_capability_count: @in_scope_capability_count,
      matched_capability_count: categories.sum { |c| c[:capabilities].size }
    }
  end

  private

  def searching?
    @search_tokens.any?
  end

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
      # An archived category leaves the matrix entirely (both modes). The
      # aggregate flips its status to "archived" the moment the archive event
      # applies; archiving an *empty* category alters no visible cells, so
      # dropping it early (rather than carrying a "pending archive" badge like a
      # capability does) keeps the grid clean without changing any ratings.
      next if category_archived?(category)

      capabilities = build_capabilities(category, ordinals, family_role_ids, selected_role_id_set)
      @in_scope_capability_count += capabilities.size
      capabilities = filter_by_search(category, capabilities) if searching?
      # Drop empty categories in view mode (clean published view) and while
      # searching. Keep them in edit mode so a freshly-added (still empty)
      # category stays visible — otherwise its "+ Add capability" affordance
      # vanishes and there's no way to populate it.
      next if capabilities.empty? && (@mode != :edit || searching?)

      {
        category: category,
        capabilities: capabilities,
        archivable: category_archivable?(category),
        pending_suggestion_count: pending_count("capability_category", category.category_id),
        pending_edit: pending_latest_edit("capability_category", category.category_id, "name"),
        description_pending_edit: pending_latest_edit("capability_category", category.category_id, "description")
      }
    end
  end

  # Whether the category itself has been archived (status flipped by the
  # aggregate on CapabilityCategoryArchived). Such categories drop out of the
  # matrix in both modes — see #build_categories.
  #
  # @return [Boolean]
  def category_archived?(category)
    category.respond_to?(:status) && category.status.to_s == "archived"
  end

  # Whether the category can be archived: it holds no genuinely-active
  # capability. Mirrors the aggregate's guard (Frameworks::Aggregate
  # #archive_capability_category, which rejects while active capabilities
  # remain) — measured against the *full* capability set, not the role-filtered
  # view, so a category that merely looks empty under the current role filter
  # isn't offered for archive while it still has capabilities elsewhere. A
  # capability staged for archive in the open draft (`pending_archive` in the
  # graph; already `:archived` in aggregate state) does not block.
  #
  # @return [Boolean]
  def category_archivable?(category)
    category.capabilities.none? do |c|
      c.status == "active" && !(c.respond_to?(:pending_archive) && c.pending_archive)
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
        pending_suggestion_count: pending_count("capability", capability.capability_id),
        pending_edit: pending_latest_edit("capability", capability.capability_id, "name"),
        description_pending_edit: pending_latest_edit("capability", capability.capability_id, "description")
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
      bound_selected_role_ids = @selected_roles
        .map(&:role_id)
        .select { |rid| binding_role_ids.include?(rid) && role_ordinals[rid]&.include?(ordinal) }

      expectation = expectations_by_ordinal[ordinal]
      unless expectation
        # Applicable (the capability is bound to a selected role with a level at
        # this ordinal) but unauthored — in edit mode emit an authoring
        # placeholder so the cell can offer "+ Add expectation"; in view mode
        # leave it nil (renders as an em-dash). A genuinely not-applicable cell
        # (no bound selected role at this ordinal) stays nil in both modes.
        if @mode == :edit && bound_selected_role_ids.any?
          cells[ordinal] = { expectation: nil, authorable: true,
                             capability_id: capability.capability_id,
                             illustration_count: 0, illustrations_by_role: {},
                             bound_selected_role_ids: bound_selected_role_ids }
        end
        next
      end

      illustrations = expectation.illustrations
        .select { |ill| selected_role_id_set.include?(ill.role_id) }

      illustrations_by_role = illustrations
        .group_by(&:role_id)
        .transform_values { |ills| ills.sort_by(&:ordinal) }

      cells[ordinal] = {
        expectation: expectation,
        illustration_count: illustrations.size,
        illustrations_by_role: illustrations_by_role,
        bound_selected_role_ids: bound_selected_role_ids,
        pending_suggestion_count: pending_count("behavioural_expectation", expectation.expectation_id),
        pending_edit: pending_latest_edit("behavioural_expectation", expectation.expectation_id, "description"),
        illustration_pending_edits: illustration_pending_edits(illustrations),
        illustration_pending_edit_details: illustration_pending_edit_details(illustrations),
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
      count = pending_count("role_illustration", ill.illustration_id)
      h[ill.illustration_id] = count if count > 0
    end
  end

  # Builds a hash of illustration_id => latest-edit descriptor for inline
  # diff rendering. Only populated for illustrations with a pending text
  # edit; illustrations with pending deletes / creates only don't appear.
  #
  # @return [Hash<String, Hash>]
  def illustration_pending_edit_details(illustrations)
    illustrations.each_with_object({}) do |ill, h|
      latest = pending_latest_edit("role_illustration", ill.illustration_id, "description")
      h[ill.illustration_id] = latest if latest
    end
  end

  # Keeps only capabilities whose searchable text contains *every* query
  # token (case-insensitive substring). Operates after the role/family
  # filter, so the text search narrows within the current role scope and
  # never resurfaces a capability the role filter excluded.
  #
  # @return [Array<Hash>]
  def filter_by_search(category, capabilities)
    capabilities.select do |cap_data|
      haystack = searchable_text(cap_data, category)
      @search_tokens.all? { |token| haystack.include?(token) }
    end
  end

  # Builds the lowercased haystack matched against the query tokens: the
  # capability's own name/description, its category name/description (so a
  # query on the category surfaces all of its capabilities), and the text of
  # every visible behavioural expectation. In edit mode the proposed values of
  # pending suggested edits are folded in too, so searching for text that only
  # exists in an unapproved proposal still surfaces the capability. Illustrations
  # are intentionally NOT included — see the `search_query` note on #initialize.
  #
  # @return [String]
  def searchable_text(cap_data, category)
    cap = cap_data[:capability]
    parts = [ category.name, category.description, cap.name, cap.description ]
    cap_data[:cells].each_value { |cell| parts << cell[:expectation]&.description }

    if @mode == :edit
      parts.concat(pending_suggested_values("capability_category", category.category_id))
      parts.concat(pending_suggested_values("capability", cap.capability_id))
      cap_data[:cells].each_value do |cell|
        next unless cell[:expectation]

        parts.concat(pending_suggested_values("behavioural_expectation", cell[:expectation].expectation_id))
      end
    end

    parts.compact.join(" ").downcase
  end

  # Proposed values of an entity's pending suggested edits (latest per field).
  # Empty in view mode (the suggestions map is empty there) and for entities
  # with no pending edits.
  #
  # @return [Array<String>]
  def pending_suggested_values(entity_type, entity_id)
    entry = @pending_suggestions[[ entity_type, entity_id ]]
    return [] unless entry && entry[:latest_by_field]

    entry[:latest_by_field].values.map { |desc| desc[:suggested_value] }
  end

  def pending_count(entity_type, entity_id)
    entry = @pending_suggestions[[ entity_type, entity_id ]]
    entry ? entry[:count] : 0
  end

  # Latest pending edit on a specific text field of an entity (used to render
  # the inline diff). The map carries the latest edit per field, so the name
  # frame and the description frame each pick their own.
  def pending_latest_edit(entity_type, entity_id, field)
    entry = @pending_suggestions[[ entity_type, entity_id ]]
    entry && entry[:latest_by_field] && entry[:latest_by_field][field]
  end
end
