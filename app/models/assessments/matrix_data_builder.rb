# frozen_string_literal: true

# Transforms framework read models and assessment ratings into a structured
# hash for the self-assessment capability matrix.
#
# Single-role variant of {Frameworks::MatrixDataBuilder}. Enriches each cell
# with the person's current self-rated frequency, binding weight/tolerance,
# and scoring output.
#
# Operates on in-memory associations — no additional queries beyond the
# initial ratings load.
#
# @example
#   data = Assessments::MatrixDataBuilder.new(
#     framework: framework, role: role, level: level,
#     person_id: person.id, cycle_id: open_cycle.cycle_id,
#     categories: eager_loaded_categories
#   ).build
#
class Assessments::MatrixDataBuilder
  VALID_CONTEXTS = %i[self manager alignment].freeze

  # @param framework [FrameworkState::Framework]
  # @param role [FrameworkState::Role] the person's assigned role
  # @param level [FrameworkState::Level] the person's assigned level
  # @param person_id [String] UUID
  # @param cycle_id [String, nil] UUID of the assessment cycle whose ratings
  #   should be shown. When nil, the builder returns no ratings (empty matrix).
  # @param categories [Array<FrameworkState::CapabilityCategory>] eager-loaded
  # @param participant_status [String, nil] current cycle participant lifecycle
  #   status (`enrolled` | `started` | `aligning` | `aligned` | `withdrawn`).
  #   Used by views to decide read-only vs interactive rendering.
  # @param context [Symbol] viewer context (`:self` | `:manager` | `:alignment`).
  #   When `:self`, manager and aligned ratings are scrubbed from the result so
  #   the assessee never receives data they shouldn't see — even via HTML
  #   inspection — until the manager formally starts alignment.
  # @param viewer_person_id [String, nil] UUID of the Person currently viewing.
  #   When nil, evidence is omitted entirely (e.g. unauthenticated paths).
  # @param viewer_sees_all_evidence [Boolean] true when the viewer is the
  #   assessee, anywhere in their manager chain, or a tenant admin. False for
  #   peers — in which case the builder only returns evidence the viewer
  #   themselves authored.
  def initialize(framework:, role:, level:, person_id:, cycle_id:, categories:,
                 context:, participant_status: nil,
                 viewer_person_id: nil, viewer_sees_all_evidence: false)
    @framework = framework
    @role = role
    @level = level
    @person_id = person_id
    @cycle_id = cycle_id
    @categories = categories
    @participant_status = participant_status
    @viewer_person_id = viewer_person_id
    @viewer_sees_all_evidence = viewer_sees_all_evidence
    @context = context&.to_sym
    return if VALID_CONTEXTS.include?(@context)

    raise ArgumentError,
      "Invalid context #{context.inspect} — expected one of #{VALID_CONTEXTS.inspect}"
  end

  # Builds the assessment matrix data structure.
  #
  # @return [Hash]
  def build
    @level = resolve_assessment_level
    @ratings_index = load_ratings
    @evidence_index = load_evidence
    @comments_index = load_comments
    @bindings_by_cap = index_bindings
    levels = build_levels
    ordinals = levels.map { |l| l[:ordinal] }
    categories = build_categories(ordinals)
    scoring_engine = build_scoring_engine(categories, perspective: primary_scoring_perspective)
    all_bindings = categories.flat_map { |c| c[:capabilities].map { |cap| cap[:binding] } }.compact
    enrich_levels_with_performance_ratios(levels, scoring_engine)
    enrich_capabilities_with_contributions(categories, scoring_engine)
    scoring = extract_scoring(scoring_engine, bindings: all_bindings)

    {
      role: @role,
      level: @level,
      person_level: @level.ordinal,
      merged_levels: levels,
      categories: categories,
      scoring: scoring,
      self_scoring: build_perspective_scoring(categories, :self_only),
      manager_scoring: hide_others? ? nil : build_perspective_scoring(categories, :manager_only),
      aligned_scoring: hide_others? ? nil : build_perspective_scoring(categories, :aligned_only),
      meeting_expectation_threshold: @framework.meeting_expectation_threshold&.to_f ||
        PersonDevelopment::Scoring::DEFAULT_MEETING_EXPECTATION_THRESHOLD,
      mastery_threshold: @framework.mastery_threshold&.to_f ||
        PersonDevelopment::Scoring::DEFAULT_MASTERY_THRESHOLD,
      inferred_level: scoring_engine.inferred_level,
      total_cells: count_total_cells(categories),
      rated_cells: count_rated_cells(categories),
      participant_status: @participant_status,
      individual_ratings_frozen: %w[aligning aligned].include?(@participant_status),
      alignment_locked: @participant_status == "aligned",
      current_level_complete: current_level_complete?(categories)
    }
  end

  private

  # Resolves the level this cycle is scored and displayed AGAINST.
  #
  # Prefers the cycle's enrollment snapshot (the role/level the person was
  # assessed at) over their *current* assignment level, so a later promotion
  # never silently re-interprets a cycle's ratings. Gated on the snapshot
  # being for the SAME role being rendered — a horizontal-move snapshot is
  # left alone (the matrix is built from the current role; applying another
  # role's level ordinal would be incoherent — deferred to role-aware
  # rendering). Falls back to the passed-in assignment level whenever there's
  # no usable snapshot (no cycle, historical enrollment, or different role).
  #
  # @return [FrameworkState::Level]
  def resolve_assessment_level
    return @level unless @cycle_id

    enrollment = AssessmentCycleEnrollment.find_by(cycle_id: @cycle_id, person_id: @person_id)
    return @level unless enrollment&.level_id
    return @level unless enrollment.role_id == @role.role_id

    @role.levels.find { |lvl| lvl.level_id == enrollment.level_id } || @level
  end

  # Builds the level columns for the person's assigned role.
  #
  # @return [Array<Hash>]
  def build_levels
    @role.levels.sort_by(&:ordinal).map do |lvl|
      { ordinal: lvl.ordinal, level_code: lvl.code, level_title: lvl.title, level_id: lvl.level_id }
    end
  end

  # Builds the category → capability → cell structure.
  #
  # @param ordinals [Array<Integer>]
  # @return [Array<Hash>]
  def build_categories(ordinals)
    @categories.filter_map do |category|
      capabilities = build_capabilities(category, ordinals)
      next if capabilities.empty?

      {
        category: category,
        deficit_threshold: category.deficit_threshold,
        person_level: @level.ordinal,
        capabilities: capabilities
      }
    end
  end

  # Builds capability data for a category, filtered to the person's role.
  #
  # @return [Array<Hash>]
  def build_capabilities(category, ordinals)
    category.capabilities.select { |c| c.status == "active" }.filter_map do |capability|
      binding = @bindings_by_cap[capability.capability_id]
      next unless binding  # skip capabilities not bound to this role

      cells = build_cells(capability, ordinals)

      {
        capability: capability,
        binding: binding,
        weight: binding.weight.to_f,
        cells: cells
      }
    end
  end

  # Builds cells for each level ordinal with expectation + current rating.
  #
  # @return [Hash<Integer, Hash>]
  def build_cells(capability, ordinals)
    expectations_by_ordinal = capability.expectations.index_by(&:level_ordinal)

    ordinals.each_with_object({}) do |ordinal, cells|
      expectation = expectations_by_ordinal[ordinal]
      next unless expectation

      rating = @ratings_index[[ capability.stable_id, ordinal ]]
      illustrations = expectation.illustrations
        .select { |ill| ill.role_id == @role.role_id }
        .sort_by(&:ordinal)

      evidence = @evidence_index[[ capability.stable_id, ordinal ]] || []
      comments = @comments_index[[ capability.stable_id, ordinal ]] || []
      visible_comment_count = comments.count { |c| !c.deleted? } +
        (@link_comment_cell_counts || {})[[ capability.stable_id, ordinal ]].to_i

      cells[ordinal] = {
        expectation: expectation,
        current_frequency: rating&.self_rated_frequency,
        manager_frequency: hide_others? ? nil : rating&.manager_rated_frequency,
        aligned_frequency: hide_others? ? nil : rating&.aligned_frequency,
        illustrations: illustrations,
        illustration_count: illustrations.size,
        evidence: evidence,
        evidence_count: evidence.size,
        comments: comments,
        comment_count: visible_comment_count
      }
    end
  end

  # Loads active evidence visible to the current viewer, indexed by
  # (capability_stable_id, level_ordinal). Evidence has no cycle scope —
  # it's framework-wide context anchored to the behavioural expectation.
  #
  # An item can be linked to several cells (multi-linkage), so the same
  # {EvidenceItem} object can appear in more than one bucket. Each item
  # carries its total active-link count (`active_link_count`) so the card
  # can render an "also linked to N other places" indicator without an
  # N+1.
  #
  # Visibility:
  # - When `viewer_sees_all_evidence: true` (assessee, manager chain, or
  #   tenant admin): returns every active item for the person + framework.
  # - When `viewer_sees_all_evidence: false` (peer): returns only items
  #   the viewer themselves authored — peers can see their own
  #   contributions in context but not others'.
  # - When `viewer_person_id` is nil: returns nothing.
  #
  # @return [Hash{[String, Integer] => Array<EvidenceItem>}]
  def load_evidence
    return {} if @viewer_person_id.nil?

    items_scope = EvidenceItem
      .active
      .for_person(@person_id)
      .for_framework(@framework.framework_id)
      .includes(:author)
    items_scope = items_scope.where(author_id: @viewer_person_id) unless @viewer_sees_all_evidence
    items_by_id = items_scope.index_by(&:id)
    return {} if items_by_id.empty?

    links = EvidenceLink.active.where(evidence_id: items_by_id.keys).to_a
    links_by_evidence = links.group_by(&:evidence_id)
    counts = links_by_evidence.transform_values(&:size)
    valences = links_by_evidence.transform_values do |item_links|
      item_links.to_h { |link| [ [ link.capability_stable_id, link.level_ordinal ], link.valence ] }
    end

    comment_stats = load_link_comment_stats(items_by_id.keys)
    # Cell-level totals so the level chip's comment glyph reflects
    # linkage discussions too (scoped to the evidence the viewer sees).
    @link_comment_cell_counts = comment_stats.values.each_with_object(Hash.new(0)) do |per_cell, totals|
      per_cell.each { |cell_key, stat| totals[cell_key] += stat[:count] }
    end

    links
      .sort_by { |link| items_by_id[link.evidence_id].recorded_at }
      .each_with_object({}) do |link, h|
        item = items_by_id[link.evidence_id]
        item.active_link_count = counts[link.evidence_id]
        item.link_valences = valences[link.evidence_id]
        item.link_comment_stats = comment_stats[link.evidence_id] || {}
        key = [ link.capability_stable_id, link.level_ordinal ]
        (h[key] ||= []) << item
      end
  end

  # Aggregates each evidence item's linkage-discussion threads into
  # per-cell stats — `evidence_id => { [stable_id, ordinal] => { count:,
  # latest_body:, latest_author_name: } }` — for the collapsed
  # count-plus-excerpt affordance on the evidence card. One query; the
  # full thread (with lifecycle rows) loads lazily on expand.
  #
  # @return [Hash{String => Hash}]
  def load_link_comment_stats(evidence_ids)
    PersonDevelopmentComment
      .active
      .where(commentable_type: PersonDevelopmentComment::EVIDENCE_LINK,
             evidence_id: evidence_ids)
      .includes(:author)
      .chronological
      .each_with_object({}) do |comment, h|
        per_item = (h[comment.evidence_id] ||= {})
        stat = (per_item[[ comment.capability_stable_id, comment.level_ordinal ]] ||=
          { count: 0, latest_body: nil, latest_author_name: nil })
        stat[:count] += 1
        stat[:latest_body] = comment.body
        stat[:latest_author_name] = comment.author&.name
      end
  end

  # Loads comments visible to the current viewer, indexed by
  # (capability_stable_id, level_ordinal). Comments have no cycle scope —
  # they are framework-wide conversation anchored to the cell.
  #
  # Returned set includes deleted comments so the thread view can
  # render tombstones in place (reply chains stay coherent). The cell's
  # `comment_count` only counts non-deleted entries.
  #
  # Comments are NOT subject to the evidence privacy gates — they are
  # informal conversation, not official record-keeping. Any viewer who
  # can see the assessment can see its comments. When `viewer_person_id`
  # is nil, the matrix is rendered without a viewer (rare; system/
  # unauthenticated paths) and we omit comments entirely.
  #
  # @return [Hash{[String, Integer] => Array<PersonDevelopmentComment>}]
  def load_comments
    return {} if @viewer_person_id.nil?

    PersonDevelopmentComment
      .for_person(@person_id)
      .for_framework(@framework.framework_id)
      .where(commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL)
      .includes(:author)
      .chronological
      .each_with_object({}) do |comment, h|
        key = [ comment.capability_stable_id, comment.level_ordinal ]
        (h[key] ||= []) << comment
      end
  end

  # Loads and indexes all AssessmentLevelRatings for this person + framework + cycle.
  #
  # Returns an empty hash when cycle_id is nil — the person isn't
  # currently in a cycle, so there are no ratings to show.
  #
  # @return [Hash{[String, Integer] => AssessmentLevelRating}]
  def load_ratings
    return {} if @cycle_id.nil?

    AssessmentLevelRating
      .for_person(@person_id)
      .for_framework(@framework.framework_id)
      .for_cycle(@cycle_id)
      .each_with_object({}) do |r, h|
        h[[ r.capability_stable_id, r.level_ordinal ]] = r
      end
  end

  # Indexes CapabilityRoleBindings for the person's role by capability_id.
  #
  # @return [Hash{String => FrameworkState::CapabilityRoleBinding}]
  def index_bindings
    @categories
      .flat_map(&:capabilities)
      .flat_map(&:bindings)
      .select { |b| b.role_id == @role.role_id }
      .index_by(&:capability_id)
  end

  # Adds :performance_ratio to each level hash for ordinals up to person_level + 1.
  # Mutates merged_levels in place. Levels beyond next level get nil.
  #
  # @param levels [Array<Hash>] from build_levels
  # @param scoring [PersonDevelopment::Scoring]
  def enrich_levels_with_performance_ratios(levels, scoring)
    next_ordinal = @level.ordinal + 1
    levels.each do |level|
      if level[:ordinal] <= next_ordinal
        level[:performance_ratio] = scoring.performance_ratio_at_level(level[:ordinal])
        level[:level_verdict] = scoring.level_verdict(level[:ordinal])
      end
    end
  end

  # Adds :contribution to each capability hash — the raw contribution score.
  #
  # @param categories_data [Array<Hash>]
  # @param scoring [PersonDevelopment::Scoring]
  def enrich_capabilities_with_contributions(categories_data, scoring)
    categories_data.each do |cat_data|
      cat_data[:capabilities].each do |cap_data|
        cap_data[:contribution] = scoring.raw_contribution(cap_data[:binding])
      end
    end
  end

  # Builds the PersonDevelopment::Scoring engine instance.
  #
  # @param categories_data [Array<Hash>] the built categories structure
  # @param perspective [Symbol] frequency perspective for scoring
  # @return [PersonDevelopment::Scoring]
  def build_scoring_engine(categories_data, perspective: :effective)
    bindings = categories_data.flat_map { |c| c[:capabilities].map { |cap| cap[:binding] } }.compact
    category_records = categories_data.map { |c| c[:category] }
    all_ordinals = build_levels.map { |l| l[:ordinal] }

    PersonDevelopment::Scoring.new(
      level_ratings: @ratings_index.values,
      bindings: bindings,
      categories: category_records,
      person_level: @level.ordinal,
      all_level_ordinals: all_ordinals,
      perspective: perspective,
      thresholds: {
        mastery_threshold: @framework.mastery_threshold&.to_f,
        meeting_expectation_threshold: @framework.meeting_expectation_threshold&.to_f,
        underperforming_threshold: @framework.underperforming_threshold&.to_f,
        overperformance_cap: @framework.overperformance_cap,
        deficit_threshold: @framework.deficit_threshold&.to_f
      }
    )
  end

  # Extracts scoring results from the engine.
  #
  # @param scoring [PersonDevelopment::Scoring]
  # @param bindings [Array<CapabilityRoleBinding>, nil] when provided, includes per-capability contributions
  # @return [Hash]
  def extract_scoring(scoring, bindings: nil)
    result = {
      performance_ratio: scoring.performance_ratio,
      meeting_expectations: scoring.meeting_expectations?,
      mastering: scoring.mastering?,
      performance_state: scoring.performance_state,
      category_results: scoring.category_results,
      promotion_readiness: scoring.promotion_readiness,
      capability_statuses: scoring.capability_statuses,
      block_reasons: scoring.block_reasons
    }
    if bindings
      result[:capability_contributions] = bindings.to_h do |b|
        [ b.capability.stable_id, scoring.raw_contribution(b) ]
      end

      # Next-level contributions power the "Gap to mastering" /
      # "Gap to promotion" panels in the hero — they show which
      # capabilities are holding the person back at the next level,
      # not at their current one. Only meaningful when a next level
      # exists in the framework.
      if scoring.has_next_level?
        result[:capability_contributions_at_next_level] = bindings.to_h do |b|
          [ b.capability.stable_id, scoring.next_level_contribution(b) ]
        end
      end
    end
    result
  end

  # Builds scoring output for a single perspective. Returns nil when no
  # ratings exist for that perspective (e.g. no manager has rated yet).
  #
  # @param categories_data [Array<Hash>]
  # @param perspective [Symbol] :self_only, :manager_only, or :aligned_only
  # @return [Hash, nil]
  def build_perspective_scoring(categories_data, perspective)
    return nil unless has_ratings_for_perspective?(perspective)

    engine = build_scoring_engine(categories_data, perspective: perspective)
    bindings = categories_data.flat_map { |c| c[:capabilities].map { |cap| cap[:binding] } }.compact
    extract_scoring(engine, bindings: bindings)
  end

  # Whether any rating records have a value for the given perspective.
  #
  # @param perspective [Symbol]
  # @return [Boolean]
  def has_ratings_for_perspective?(perspective)
    field =
      case perspective
      when :self_only    then :self_rated_frequency
      when :manager_only then :manager_rated_frequency
      when :aligned_only then :aligned_frequency
      else return true
      end

    @ratings_index.values.any? { |r| r.public_send(field).present? }
  end

  # When the viewer is the assessee themselves, hide manager and aligned data
  # until alignment formally begins. Defense-in-depth — the data never reaches
  # the HTML, not just the visible UI.
  def hide_others?
    @context == :self
  end

  # In :self context the effective fallback chain (aligned → manager → self)
  # would otherwise leak manager-derived numbers into the primary `scoring`
  # result. Force the engine to self-only so the fallback collapses safely.
  def primary_scoring_perspective
    @context == :self ? :self_only : :effective
  end

  def count_total_cells(categories)
    categories.sum { |c| c[:capabilities].sum { |cap| cap[:cells].size } }
  end

  def count_rated_cells(categories)
    categories.sum do |c|
      c[:capabilities].sum do |cap|
        cap[:cells].count { |_, cell| cell[:current_frequency].present? }
      end
    end
  end

  # Whether every capability with a cell at the person's current level has been
  # rated in the viewer's perspective — the "Assessment Complete" signal. Same
  # numerator/denominator as the hero's coverage gate, at full coverage. A role
  # with no current-level cells is never "complete" (nothing to finish).
  def current_level_complete?(categories)
    cells = categories
      .flat_map { |c| c[:capabilities] }
      .filter_map { |cap| cap[:cells][@level.ordinal] }
    return false if cells.empty?

    cells.all? { |cell| primary_cell_frequency(cell).present? }
  end

  # The frequency that counts as "rated" for the active context.
  def primary_cell_frequency(cell)
    case @context
    when :self      then cell[:current_frequency]
    when :manager   then cell[:manager_frequency]
    when :alignment then cell[:aligned_frequency]
    end
  end
end
