# frozen_string_literal: true

# Transforms framework read models and assessment ratings into a structured
# hash for the self-assessment capability matrix.
#
# Single-role variant of {Frameworks::MatrixDataBuilder}. Enriches each cell
# with the person's current self-rated frequency, binding weight/tolerance,
# and scoring output.
#
# Beyond loading the role scope and the ratings, works on the eager-loaded
# associations — no per-cell queries.
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

  # Builds the matrix for an assignment read through a lens — the one way
  # the assessment page, its frames, the rating responses and the MCP score
  # read an assignment, so they all see the same cells, the same disclosure
  # and the same floor.
  #
  # @param lens [Assessments::Lens]
  # @param context [Symbol] :self, :manager or :alignment
  # @param viewer_person_id [String, nil]
  # @param viewer_sees_all_evidence [Boolean]
  # @return [Hash] see {#build}
  def self.for_lens(lens:, context:, viewer_person_id: nil, viewer_sees_all_evidence: false)
    assignment = lens.assignment
    status = assignment.current_open_cycle_participation&.status
    new(
      framework: FrameworkState::Framework.find_by!(framework_id: assignment.framework_id),
      lens: lens,
      person_id: assignment.person_id,
      cycle_id: assignment.current_open_cycle&.cycle_id,
      categories: FrameworkState::CapabilityCategory
        .where(framework_id: assignment.framework_id, status: "active")
        .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
        .order(:ordinal),
      participant_status: status,
      disclosure: Assessments::Disclosure.for(lens: lens, participant_status: status),
      context: context,
      viewer_person_id: viewer_person_id,
      viewer_sees_all_evidence: viewer_sees_all_evidence
    ).build
  end

  # @param framework [FrameworkState::Framework]
  # @param role [FrameworkState::Role, nil] the role to read against; taken
  #   from +lens+ when one is given
  # @param level [FrameworkState::Level, nil] the level to read against;
  #   taken from +lens+ when one is given
  # @param lens [Assessments::Lens, nil] the role and level the page is read
  #   against, with the home it is read from (ADR-22). When nil the builder
  #   reads +role+ as its own home and resolves the level from the cycle's
  #   enrollment snapshot itself.
  # @param home_level [Integer, nil] the home level's ordinal — the floor
  #   below which unrated cells count as consistent. Taken from +lens+ when
  #   one is given; defaults to the level read.
  # @param disclosure [Assessments::Disclosure, nil] the cells whose manager
  #   and aligned ratings the assessee may see. Only consulted in `:self`;
  #   nil discloses nothing.
  # @param person_id [String] UUID
  # @param cycle_id [String, nil] UUID of the assessment cycle whose ratings
  #   should be shown. When nil, the builder returns no ratings (empty matrix).
  # @param categories [Array<FrameworkState::CapabilityCategory>] eager-loaded
  # @param participant_status [String, nil] current cycle participant lifecycle
  #   status (`enrolled` | `started` | `aligning` | `aligned` | `withdrawn`).
  #   Sourced from the current OPEN cycle's participation, so the terminal
  #   `concluded` status (closed cycles only) never reaches this builder.
  #   Used by views to decide read-only vs interactive rendering.
  # @param context [Symbol] viewer context (`:self` | `:manager` | `:alignment`).
  #   When `:self`, manager and aligned ratings are scrubbed from every cell
  #   +disclosure+ doesn't name, so the assessee never receives data they
  #   shouldn't see — even via HTML inspection.
  # @param viewer_person_id [String, nil] UUID of the Person currently viewing.
  #   When nil, evidence is omitted entirely (e.g. unauthenticated paths).
  # @param viewer_sees_all_evidence [Boolean] true when the viewer is the
  #   assessee, anywhere in their manager chain, or a tenant admin. False for
  #   peers — in which case the builder only returns evidence the viewer
  #   themselves authored.
  def initialize(framework:, person_id:, cycle_id:, categories:, context:,
                 role: nil, level: nil, lens: nil, home_level: nil, disclosure: nil,
                 participant_status: nil,
                 viewer_person_id: nil, viewer_sees_all_evidence: false)
    # Repopulated by load_evidence; eager default so build_cells never
    # depends on load ordering.
    @link_comment_cell_counts = {}
    @framework = framework
    @lens = lens
    @role = lens&.role || role
    @level = lens&.level || level
    @home_level_ordinal = lens&.home_level&.ordinal || home_level
    @disclosure = disclosure || Assessments::Disclosure.none
    @person_id = person_id
    @cycle_id = cycle_id
    @categories = categories
    @participant_status = participant_status
    @viewer_person_id = viewer_person_id
    @viewer_sees_all_evidence = viewer_sees_all_evidence
    @context = context&.to_sym
    raise ArgumentError, "Pass a lens, or a role and a level" unless @role && @level
    return if VALID_CONTEXTS.include?(@context)

    raise ArgumentError,
      "Invalid context #{context.inspect} — expected one of #{VALID_CONTEXTS.inspect}"
  end

  # Builds the assessment matrix data structure.
  #
  # @return [Hash]
  def build
    @level = resolve_assessment_level unless @lens
    @home_level_ordinal ||= @level.ordinal
    @role_scope = @lens&.scope ||
      Assessments::RoleScope.for(role_id: @role.role_id, framework_id: @framework.framework_id)
    @home_scope = @lens&.home_scope || @role_scope
    @ratings_index = load_ratings
    @evidence_index = load_evidence
    @comments_index = load_comments
    @bindings_by_cap = index_bindings
    levels = build_levels
    ordinals = levels.map { |l| l[:ordinal] }
    categories = build_categories(ordinals)
    @all_ordinals = ordinals
    @all_bindings = categories.flat_map { |c| c[:capabilities].map { |cap| cap[:binding] } }.compact
    @expectation_cells = expectation_cells(categories)
    scoring_engine = build_scoring_engine(categories, perspective: primary_scoring_perspective)
    scoring = extract_scoring(scoring_engine, bindings: @all_bindings)

    {
      role: @role,
      level: @level,
      person_level: @level.ordinal,
      # The lens the page is read against (nil when the caller passed none),
      # the home level it is read from, and the ordinal below which unrated
      # cells count as consistent — the level chips paint that default.
      lens: @lens,
      home_level: @home_level_ordinal,
      assumed_below: assumed_below,
      merged_levels: levels,
      categories: categories,
      scoring: scoring,
      emphasised_capabilities: emphasised_capabilities(categories, scoring),
      self_scoring: build_perspective_scoring(categories, :self_only),
      # Whole-page manager and aligned scores stay withheld from the assessee
      # unless every cell they are built over is disclosed: a number built
      # over a mix of disclosed and private cells would say something no
      # cell does.
      manager_scoring: withhold_page_scores? ? nil : build_perspective_scoring(categories, :manager_only),
      aligned_scoring: withhold_page_scores? ? nil : build_perspective_scoring(categories, :aligned_only),
      # All three bands, because the explanation layer (#414) must name the
      # framework's own numbers rather than the shipped 80/95/150.
      underperforming_threshold: @framework.underperforming_threshold&.to_f ||
        PersonDevelopment::Scoring::DEFAULT_UNDERPERFORMING_THRESHOLD,
      meeting_expectation_threshold: @framework.meeting_expectation_threshold&.to_f ||
        PersonDevelopment::Scoring::DEFAULT_MEETING_EXPECTATION_THRESHOLD,
      mastery_threshold: @framework.mastery_threshold&.to_f ||
        PersonDevelopment::Scoring::DEFAULT_MASTERY_THRESHOLD,
      total_cells: count_total_cells(categories),
      rated_cells: count_rated_cells(categories),
      participant_status: @participant_status,
      # The alignment against the role being read, if one has started — it
      # decides whether the page is the alignment conversation. Frozen cells
      # beyond it are marked per cell (`frozen_by`).
      lens_alignment: lens_alignment,
      # Every other role alignment has started against this cycle — the
      # header's "Aligning · PM3" chips.
      lens_alignments: @disclosure.lens_alignments,
      # Lens-independent, so the page's feed reuses it rather than building
      # a second one.
      disclosure: @disclosure,
      individual_ratings_frozen: lens_alignment_started?,
      alignment_locked: lens_alignment_completed?,
      current_level_complete: current_level_complete?(categories),
      current_level_work: current_level_work(categories)
    }
  end

  private

  # Resolves the level this cycle is scored and displayed AGAINST when the
  # caller passed no lens. A lens settles the level itself
  # ({Assessments::Lens.resolve} reads the snapshot for the home and takes a
  # lens level as given), so this runs only for callers reading a role as
  # its own home.
  #
  # Prefers the cycle's enrollment snapshot (the role/level the person was
  # assessed at) over their *current* assignment level, so a later promotion
  # never silently re-interprets a cycle's ratings. A snapshot for another
  # role is ignored: rendering one role at another role's level is a lens,
  # and a lens says so. Falls back to the passed-in level whenever there's
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
        cells: cells,
        # Whether the record reads this capability at all — false only
        # under a lens, on a capability the lens role adds.
        in_home_role: @home_scope.capability_stable_ids.include?(capability.stable_id)
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
        @link_comment_cell_counts[[ capability.stable_id, ordinal ]].to_i

      hidden = hide_others?(capability.stable_id, ordinal)
      cells[ordinal] = {
        expectation: expectation,
        current_frequency: rating&.self_rated_frequency,
        manager_frequency: hidden ? nil : rating&.manager_rated_frequency,
        aligned_frequency: hidden ? nil : rating&.aligned_frequency,
        # Carried-forward (seeded, unconfirmed) values that still ask to be
        # confirmed — drives the lighter pill/chip treatment and the "to
        # confirm" counts. Below the floor the scale already assumes the cell
        # met, so a carried value there asks nothing (#480). Same privacy
        # gate as the values.
        current_frequency_carried: asks_confirmation?(ordinal, rating&.self_rating_carried?),
        manager_frequency_carried: !hidden && asks_confirmation?(ordinal, rating&.manager_rating_carried?),
        # Whether the record reads this cell (ADR-22).
        in_home_scope: @home_scope.include?(capability.stable_id, ordinal),
        # The started alignment that froze self and manager ratings here —
        # any role's, whichever lens the page is read through — and whether
        # the agreed value can still move.
        frozen_by: @disclosure.frozen_by(capability.stable_id, ordinal),
        agreed_locked: @disclosure.agreed_value_locked?(capability.stable_id, ordinal,
                                                        agreed: rating&.aligned_frequency.present?),
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

  # Loads and indexes this person's ratings in the cycle, inside the role's
  # cells — a rating on a capability the role doesn't bind would otherwise
  # count as having rated in a perspective (ADR-22).
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
      .within(@role_scope)
      .each_with_object({}) do |r, h|
        h[[ r.capability_stable_id, r.level_ordinal ]] = r
      end
  end

  # Indexes the role's active bindings by capability_id — from the same
  # RoleScope every other rating reader uses, so there is one definition of
  # what the role binds.
  #
  # @return [Hash{String => FrameworkState::CapabilityRoleBinding}]
  def index_bindings
    @role_scope.bindings.index_by(&:capability_id)
  end

  # Builds the PersonDevelopment::Scoring engine instance.
  #
  # @param categories_data [Array<Hash>] the built categories structure
  # @param perspective [Symbol] frequency perspective for scoring
  # @return [PersonDevelopment::Scoring]
  def build_scoring_engine(categories_data, perspective: :effective)
    PersonDevelopment::Scoring.new(
      level_ratings: @ratings_index.values,
      bindings: @all_bindings,
      categories: categories_data.map { |c| c[:category] },
      person_level: @level.ordinal,
      home_level: @home_level_ordinal,
      all_level_ordinals: @all_ordinals,
      expectation_cells: @expectation_cells,
      perspective: perspective,
      thresholds: @framework.scoring_thresholds
    )
  end

  # The (capability_stable_id, level_ordinal) cells that carry a behavioural
  # expectation — exactly the cells the matrix renders. The engine normalises
  # each level's band over these, so a capability with no next-level
  # expectation neither earns nor owes next-level credit.
  #
  # @param categories_data [Array<Hash>]
  # @return [Set<Array(String, Integer)>]
  def expectation_cells(categories_data)
    categories_data.flat_map do |category|
      category[:capabilities].flat_map do |cap|
        stable_id = cap[:capability].stable_id
        cap[:cells].keys.map { |ordinal| [ stable_id, ordinal ] }
      end
    end.to_set
  end

  # Extracts scoring results from the engine.
  #
  # @param scoring [PersonDevelopment::Scoring]
  # @param bindings [Array<CapabilityRoleBinding>, nil] when provided, includes per-capability contributions
  # @return [Hash]
  def extract_scoring(scoring, bindings: nil)
    result = {
      performance_ratio: scoring.performance_ratio,
      components: scoring.components,
      meeting_expectations: scoring.meeting_expectations?,
      mastering: scoring.mastering?,
      performance_state: scoring.performance_state,
      category_results: scoring.category_results,
      promotion_readiness: scoring.promotion_readiness,
      capability_statuses: scoring.capability_statuses,
      block_reasons: scoring.block_reasons
    }
    if bindings

      # The same scale at the two lower altitudes — one card, one category —
      # so every surface reads the same number and vocabulary.
      # The two binding facts beside the number, so the card, the explainer
      # and the MCP payload read them off the hash they already hold, and
      # "Required" is the engine's own answer rather than a mirror of it.
      result[:capability_scores] = bindings.to_h do |b|
        [ b.capability.stable_id,
          scoring.capability_components(b).merge(
            state: scoring.capability_state(b), weight: b.weight.to_f, required: scoring.mandatory?(b)
          ) ]
      end
      result[:category_scores] = bindings.map { |b| b.capability.category_id }.uniq.to_h do |category_id|
        [ category_id, scoring.category_components(category_id).merge(state: scoring.category_state(category_id)) ]
      end

      # The hero's gap panel points at the level above, so it needs every
      # capability scored THERE — what share of the next level each one
      # already shows, on the same scale as every other number on screen.
      # Only meaningful when a next level exists in the framework.
      result[:capability_scores_at_next_level] = scoring.capability_scores_at(scoring.next_level_ordinal) if
        scoring.has_next_level?
    end
    result
  end

  # The capabilities whose binding changes how a rating lands — a weight
  # other than 1, or a tolerance of 0 — for the explainer's list.
  #
  # @return [Array<Hash>] `{ stable_id:, name:, weight:, required: }`
  def emphasised_capabilities(categories, scoring)
    categories.flat_map { |c| c[:capabilities] }.filter_map do |cap|
      capability = cap[:capability]
      score = scoring.dig(:capability_scores, capability.stable_id)
      next unless score && (PersonDevelopment::Scoring.weighted?(score[:weight]) || score[:required])

      { stable_id: capability.stable_id, name: capability.name,
        weight: score[:weight], required: score[:required] }
    end
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
    extract_scoring(engine, bindings: @all_bindings)
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
  # on every cell the disclosure doesn't name. Defense-in-depth — the data
  # never reaches the HTML, not just the visible UI.
  def hide_others?(capability_stable_id, level_ordinal)
    self_context? && !@disclosure.include?(capability_stable_id, level_ordinal)
  end

  def self_context?
    @context == :self
  end

  def withhold_page_scores?
    self_context? && !@disclosure.covers_all?(@role_scope.cells)
  end

  # @return [Assessments::Disclosure::Alignment, nil]
  def lens_alignment
    return @lens_alignment if defined?(@lens_alignment)

    @lens_alignment = @disclosure.alignment_for(@role.role_id) if @lens
  end

  # Without a lens, or on the home role, the participation's own status is
  # the home alignment's lifecycle — as it always was.
  def lens_alignment_started?
    return Assessments::Disclosure::STARTED_STATUSES.include?(@participant_status) if home_lifecycle?

    !lens_alignment.nil?
  end

  def lens_alignment_completed?
    return @participant_status == "aligned" if home_lifecycle?

    lens_alignment&.aligned? || false
  end

  def home_lifecycle?
    @lens.nil? || @lens.home_role?
  end

  # In :self context the effective fallback chain (aligned → manager → self)
  # would otherwise leak manager-derived numbers into the primary `scoring`
  # result. Force the engine to self-only so the fallback collapses safely.
  def primary_scoring_perspective
    self_context? ? :self_only : :effective
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

  # Whether every capability with a cell at the person's current level has a
  # VETTED (human-owned) rating in the viewer's perspective — the "Assessment
  # Complete" signal. Same denominator as the hero's coverage gate, but a
  # DELIBERATELY stricter numerator: the hero counts carried values (score is
  # about data), while Complete excludes them until confirmed (the pill is
  # about this cycle's work). A role with no current-level cells is never
  # "complete" (nothing to finish).
  def current_level_complete?(categories)
    cells = categories
      .flat_map { |c| c[:capabilities] }
      .filter_map { |cap| cap[:cells][@level.ordinal] }
    return false if cells.empty?

    # Complete means VETTED: a carried-forward value doesn't count until
    # confirmed or changed (mirrors Assessments::LevelCoverage).
    cells.all? { |cell| primary_cell_frequency(cell).present? && !primary_cell_carried?(cell) }
  end

  # What is left to do at the person's current level in the viewer's
  # perspective: cells with no value, and carried values still to confirm.
  # A cell a started alignment froze can't be confirmed, so it isn't owed.
  #
  # @return [Hash{Symbol=>Integer}] :unrated, :to_confirm
  def current_level_work(categories)
    cells = categories.flat_map { |c| c[:capabilities] }.filter_map { |cap| cap[:cells][@level.ordinal] }
    {
      unrated: cells.count { |cell| primary_cell_frequency(cell).blank? },
      to_confirm: cells.count { |cell| Assessments::CarriedCell.to_confirm?(cell, @context) }
    }
  end

  # The ordinal below which an unrated cell counts as met: the lower of the
  # level read and the home level, as {PersonDevelopment::Scoring} floors it.
  def assumed_below
    [ @level.ordinal, @home_level_ordinal ].min
  end

  def asks_confirmation?(ordinal, carried)
    carried.present? && ordinal >= assumed_below
  end

  # The frequency that counts as "rated" for the active context.
  def primary_cell_frequency(cell)
    case @context
    when :self      then cell[:current_frequency]
    when :manager   then cell[:manager_frequency]
    when :alignment then cell[:aligned_frequency]
    end
  end

  # Whether the active context's value is carried-forward (seeded,
  # unconfirmed). Aligned values are never seeded.
  def primary_cell_carried?(cell)
    case @context
    when :self    then cell[:current_frequency_carried] || false
    when :manager then cell[:manager_frequency_carried] || false
    else false
    end
  end
end
