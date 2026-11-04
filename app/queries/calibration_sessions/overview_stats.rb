# frozen_string_literal: true

# Assembles the calibration overview for one session: the readiness card,
# the rater tendency strip and the capability divergence board
# (docs/architecture/calibration-sessions.md, "Overview").
#
# All statistics are computed over **at-level manager ratings** — each
# population member's cells at their cycle-assessed level (the ADR-19
# enrollment snapshot). At-level frequencies are level-normalized by
# construction (everyone is measured against their own bar), which keeps
# every number on screen explainable to the room: "Raj's average at-level
# rating is 0.6 bands below the org mean" needs no scoring-model caveats.
#
# Only population members attributed to a *participant* rater (via the
# same recorded-manager/delegation semantics as the seed) contribute to the
# tendency and divergence statistics — reference people whose rater isn't
# in the room are excluded by design (you can't calibrate someone in
# absentia). Readiness covers the whole population, reference people
# included: their ratings are still something the room reads.
#
# Readiness is cell coverage, not people coverage. Every percentage on the
# card shares one denominator — a person's at-level cells, the role scope
# at their assessed level — so rating coverage, the carried share and
# evidence coverage add up and move with every single rating.
#
# The two failure modes stay separable:
# - **spread** — raw between-rater disagreement on a capability.
# - **residual_spread** — the disagreement remaining after subtracting
#   each rater's overall tendency offset.
# - **divergence_score** = min(spread, residual_spread) — the ranking and
#   flagging signal. Both bounds are required: pure tendency shows raw
#   spread with ~0 residual, while raters who AGREE on a capability
#   despite opposite overall tendencies show a large residual with ~0 raw
#   spread — the correction manufactures divergence there, and flagging a
#   capability the room agrees on as "raters disagree" would read as
#   nonsense. Only disagreement that is real AND unexplained by tendency
#   marks an unclear-expectation candidate.
class CalibrationSessions::OverviewStats
  # Equal-interval band values (0–3) derived from the canonical frequency
  # vocabulary, so a rename/addition can't silently skew the calibration
  # stats. Deliberately NOT PersonDevelopment::Scoring::FREQUENCY —
  # calibration compares raters on an ordinal scale, not scoring
  # contribution.
  FREQUENCY_VALUES = AssessmentLevelRating::FREQUENCIES
    .each_with_index.to_h { |frequency, index| [ frequency, index.to_f ] }.freeze

  # Raters with fewer rated cells than this are shown with their n but
  # never badged — small samples always look extreme.
  SMALL_N = 3

  # Divergence score (in rating bands) at or above which a capability is
  # flagged as a likely unclear expectation.
  DIVERGENCE_FLAG_THRESHOLD = 1.0

  # Minimum rated cells across raters before a capability may be flagged.
  FLAG_MIN_CELLS = 4

  # @param session [CalibrationSession]
  # @param population_seeds [CalibrationSessions::PopulationSeeds, nil]
  #   pass the request's existing instance so the attribution queries run
  #   once per render, not once per consumer
  def initialize(session:, population_seeds: nil)
    @session = session
    @population_seeds = population_seeds
  end

  # @return [Hash] `{ org_mean:, raters: [...], capabilities: [...],
  #   insufficient_capability_count:, readiness: {...} }`
  #   Raters: `{ participant_id:, report_count:, rated_count:, cell_count:, mean:,
  #   org_delta:, distribution: {frequency => count}, self_gap:, evidence_pct:,
  #   carried_count:, small_n:, cell_total:, unrated_count:, evidence_cell_count:,
  #   coverage_pct:, carried_pct:, evidence_coverage_pct:, ready_state: }` —
  #   `cell_count` is rated at-level cells and `carried_count` the ones seeded
  #   from a prior cycle; `evidence_pct` is backed cells over RATED cells.
  #   The coverage fields share one denominator, `cell_total` (every at-level
  #   cell of this rater's reports): `coverage_pct` = rated, `carried_pct` =
  #   carried, `evidence_coverage_pct` = cells with ≥1 active evidence link.
  #   Fractions 0–1, nil when `cell_total` is 0. `ready_state` names the work
  #   left — see {.ready_state}.
  #   Readiness: the population-wide totals on the same denominator
  #   (`{ cell_total:, cell_count:, carried_count:, unrated_count:, evidence_cell_count:,
  #   coverage_pct:, carried_pct:, evidence_coverage_pct:, reference: [...] }`),
  #   where `reference` holds one row per out-of-session rater
  #   (`{ rater_id:, person_count:, ...same coverage fields }`, `rater_id`
  #   nil when nobody is recorded as the person's manager).
  #   Capabilities (sorted most-divergent first): `{ stable_id:, name:, category_name:,
  #   rater_means: {participant_id => {mean:, n:}}, spread:, residual_spread:,
  #   divergence_score:, flagged:, carried_count:, cell_count: }` — here
  #   `cell_count`/`carried_count` cover ONLY the raters sitting at the two
  #   means that define `spread`, so they describe the comparison on screen.
  #   Usually a subset of the capability's cells; when every rater ties, min
  #   and max are the same mean and the "comparison" is the whole agreeing
  #   set, so the counts can equal it.
  #
  #   Both row shapes are part of the `calibration_sessions_overview` MCP
  #   response (Operations::CalibrationSessions::Overview passes them
  #   through), so additions here are a client-visible contract change.
  def call
    @call ||= build
  end

  # The work a rater (or the whole population) has left, by precedence:
  # an unrated cell outranks a carried one, because confirming needs a value
  # to confirm.
  #
  # @param cell_total [Integer]
  # @param rated [Integer]
  # @param carried [Integer]
  # @return [String] "no_cells" | "unrated" | "to_confirm" | "ready"
  def self.ready_state(cell_total:, rated:, carried:)
    return "no_cells" if cell_total.zero?
    return "unrated" if rated < cell_total
    return "to_confirm" if carried.positive?

    "ready"
  end

  private

  def build
    rated = rated_cells
    org_mean = mean(rated.map { |cell| cell[:value] })
    raters = rater_rows(rated, org_mean)
    capabilities = capability_rows(rated, raters, org_mean)

    {
      org_mean: org_mean,
      raters: raters,
      capabilities: capabilities,
      insufficient_capability_count: @insufficient_capability_count || 0,
      readiness: readiness
    }
  end

  # ── inputs ──

  def participant_ids
    @participant_ids ||= @session.participants.pluck(:person_id)
  end

  def calibrant_ids
    @calibrant_ids ||= @session.calibrants.pluck(:person_id)
  end

  # population person_id => participant (rater) person_id, for members
  # attributed to a rater in the room.
  def rater_for
    # The canonical single attribution (PopulationSeeds#attribution) so the
    # strip, the drill-in, and the revisit op can never credit the same
    # person to different raters. Attributed calibrants only — reference
    # people without an in-session rater are excluded from tendency stats.
    @rater_for ||= (@population_seeds || CalibrationSessions::PopulationSeeds.new(
      framework_id: @session.framework_id,
      participant_ids: participant_ids,
      facilitator_id: @session.facilitator_id
    )).attribution.slice(*calibrant_ids)
  end

  # person_id => assessed level ordinal (cycle enrollment snapshot), for the
  # whole population — readiness covers reference people too.
  def assessed_ordinals
    @assessed_ordinals ||= AssessmentCycleEnrollment.active
      .where(cycle_id: @session.cycle_id, person_id: calibrant_ids)
      .pluck(:person_id, :level_ordinal).to_h
  end

  # person_id => the cells their assessed role reads (ADR-22), so a rating on
  # another role's capability never enters a rater's tendency.
  def role_scopes
    @role_scopes ||= Assessments::RoleScope.for_people(
      cycle_id: @session.cycle_id, framework_id: @session.framework_id, person_ids: calibrant_ids
    )
  end

  # person_id => the capability stable_ids of their at-level cells: the one
  # denominator every readiness percentage shares. A person not enrolled in
  # the cycle has no assessed level, so no cells.
  def at_level_cells
    @at_level_cells ||= calibrant_ids.index_with do |person_id|
      ordinal = assessed_ordinals[person_id]
      next Set.new unless ordinal

      role_scopes.fetch(person_id).at_level(ordinal).cells.to_set(&:first)
    end
  end

  # One entry per manager-rated at-level cell:
  # { person_id:, rater_id:, capability_stable_id:, frequency:, value:,
  #   self_value:, carried: }
  #
  # `carried` marks a value seeded from the rater's previous cycle and not
  # confirmed this one (ADR-20). Carried values still COUNT — they are real
  # data, and excluding them would silently change every denominator on
  # screen — but the surfaces mark them, because a tendency nobody expressed
  # this cycle and a disagreement between two unexamined numbers are both
  # things the room should discount rather than debate.
  def rated_cells
    @rated_cells ||= population_rated_cells.filter_map do |cell|
      rater_id = rater_for[cell[:person_id]]
      cell.merge(rater_id: rater_id) if rater_id
    end
  end

  # The same cells for the whole population, before attribution — readiness
  # counts a reference person's ratings, the tendency stats never do.
  def population_rated_cells
    @population_rated_cells ||= AssessmentLevelRating
      .for_cycle(@session.cycle_id)
      .within(role_scopes)
      .where(level_ordinal: assessed_ordinals.values.uniq)
      .where.not(manager_rated_frequency: nil)
      .pluck(:person_id, :level_ordinal, :capability_stable_id,
             :manager_rated_frequency, :self_rated_frequency, :manager_rating_source)
      .filter_map do |person_id, level_ordinal, stable_id, manager_frequency, self_frequency, source|
        # The level filter above is population-wide; keep only each person's
        # OWN assessed level.
        next unless assessed_ordinals[person_id] == level_ordinal

        {
          person_id: person_id,
          capability_stable_id: stable_id,
          frequency: manager_frequency,
          value: FREQUENCY_VALUES.fetch(manager_frequency),
          self_value: self_frequency && FREQUENCY_VALUES.fetch(self_frequency),
          # Only "seeded" is carried; nil is a legacy/factory row and counts
          # as human, matching Assessments::LevelCoverage.
          carried: source == "seeded"
        }
      end
  end

  # ── tendency strip ──

  def rater_rows(rated, org_mean)
    by_rater = rated.group_by { |cell| cell[:rater_id] }

    participant_ids.map do |participant_id|
      cells = by_rater.fetch(participant_id, [])
      report_ids = rater_for.select { |_, rater| rater == participant_id }.keys
      rater_mean = mean(cells.map { |c| c[:value] })
      gaps = cells.filter_map { |c| c[:self_value] && (c[:value] - c[:self_value]) }

      {
        participant_id: participant_id,
        report_count: report_ids.size,
        rated_count: cells.map { |c| c[:person_id] }.uniq.size,
        mean: rater_mean,
        org_delta: rater_mean && org_mean ? (rater_mean - org_mean).round(2) : nil,
        distribution: FREQUENCY_VALUES.keys.index_with { |f| cells.count { |c| c[:frequency] == f } },
        self_gap: gaps.any? ? mean(gaps) : nil,
        evidence_pct: evidence_pct(cells),
        small_n: cells.size < SMALL_N
      }.merge(coverage_for(report_ids))
    end
  end

  # ── readiness ──

  def readiness
    attributed = rater_for.keys.to_set
    reference_ids = calibrant_ids.reject { |person_id| attributed.include?(person_id) }

    coverage_for(calibrant_ids).merge(
      reference: reference_ids.group_by { |person_id| reference_rater_ids[person_id] }
        .map { |rater_id, ids| { rater_id: rater_id, person_count: ids.size }.merge(coverage_for(ids)) }
    )
  end

  # Coverage over a set of people's at-level cells, every share on that one
  # denominator so the bar segments add up.
  def coverage_for(person_ids)
    total = person_ids.sum { |person_id| at_level_cells.fetch(person_id, Set.new).size }
    cells = person_ids.flat_map { |person_id| rated_by_person.fetch(person_id, []) }
    rated = cells.size
    carried = cells.count { |c| c[:carried] }
    backed = person_ids.sum do |person_id|
      ordinal = assessed_ordinals[person_id]
      at_level_cells.fetch(person_id, Set.new).count do |stable_id|
        backed_cell_keys.include?([ person_id, stable_id, ordinal ])
      end
    end

    {
      cell_total: total,
      cell_count: rated,
      # How much is inherited rather than vetted this cycle. Disclosure
      # only: a carried rating is still the rater's rating, so this NEVER
      # softens the tendency it sits beside — it tells the room the owner
      # has work to do confirming it.
      carried_count: carried,
      unrated_count: total - rated,
      evidence_cell_count: backed,
      coverage_pct: share(rated, total),
      carried_pct: share(carried, total),
      evidence_coverage_pct: share(backed, total),
      ready_state: self.class.ready_state(cell_total: total, rated: rated, carried: carried)
    }
  end

  def rated_by_person
    @rated_by_person ||= population_rated_cells.group_by { |cell| cell[:person_id] }
  end

  # The manager a reference person's ratings belong to — recorded reporting
  # manager first, the live org chart otherwise (PopulationSeeds' rule).
  def reference_rater_ids
    @reference_rater_ids ||= begin
      recorded = RecordedReportingManager.for_framework(@session.framework_id)
        .where(person_id: calibrant_ids).pluck(:person_id, :manager_id).to_h
      live = Person.where(id: calibrant_ids - recorded.keys).pluck(:id, :manager_id).to_h
      live.merge(recorded)
    end
  end

  # Two decimals, but never rounded onto an edge the counts haven't reached:
  # 249 of 250 cells reads 0.99, not a 1.0 beside "1 unrated", and one
  # carried cell reads 0.01, not 0.0.
  def share(part, total)
    return nil if total.zero?

    (part.to_f / total).round(2).clamp(part.positive? ? 0.01 : 0.0, part < total ? 0.99 : 1.0)
  end

  # Fraction of this rater's rated at-level cells carrying ≥1 active
  # evidence link (on an active item).
  def evidence_pct(cells)
    return nil if cells.empty?

    backed = cells.count do |cell|
      backed_cell_keys.include?([ cell[:person_id], cell[:capability_stable_id], assessed_ordinals[cell[:person_id]] ])
    end
    (backed.to_f / cells.size).round(2)
  end

  def backed_cell_keys
    @backed_cell_keys ||= begin
      links = EvidenceLink
        .where(link_status: "active", framework_id: @session.framework_id, person_id: calibrant_ids)
        .pluck(:evidence_id, :person_id, :capability_stable_id, :level_ordinal)
      active_evidence_ids = EvidenceItem.active.where(id: links.map(&:first).uniq).pluck(:id).to_set
      links.filter_map do |evidence_id, person_id, stable_id, ordinal|
        [ person_id, stable_id, ordinal ] if active_evidence_ids.include?(evidence_id)
      end.to_set
    end
  end

  # ── divergence board ──

  def capability_rows(rated, raters, org_mean)
    rater_offsets = raters.to_h do |row|
      [ row[:participant_id], row[:mean] && org_mean ? row[:mean] - org_mean : 0.0 ]
    end

    grouped = rated.group_by { |cell| cell[:capability_stable_id] }
    rows = grouped.filter_map do |stable_id, cells|
      by_rater = cells.group_by { |c| c[:rater_id] }
      if by_rater.size < 2
        @insufficient_capability_count = (@insufficient_capability_count || 0) + 1
        next
      end

      rater_means = by_rater.transform_values do |rater_cells|
        { mean: mean(rater_cells.map { |c| c[:value] }), n: rater_cells.size }
      end
      means = rater_means.values.map { |v| v[:mean] }
      residuals = rater_means.map { |rater_id, v| v[:mean] - (rater_offsets[rater_id] || 0.0) }
      spread = (means.max - means.min).round(2)
      # The two raters whose means ARE the spread — the comparison the row
      # displays. Carried state is counted against their cells only, so the
      # note can't reassure ("2 of 20") while the gap on screen is wholly
      # inherited, nor alarm about a carried cell belonging to a third rater
      # who isn't part of the comparison at all.
      #
      # EVERY rater at either extreme, not one per end: two raters sharing the
      # low mean are equally part of the gap on screen, and picking one of
      # them (by whatever tiebreak) would let the same data render different
      # carried counts depending on ids. Means are rounded to 2dp from the
      # same values, so a genuine tie compares equal here.
      #
      # When every rater ties, min == max and all of them are "compared" —
      # correct: the row's spread is zero and the note describes the whole
      # agreeing set.
      low, high = means.minmax
      extremes = rater_means.filter_map do |rater_id, v|
        rater_id if v[:mean] == low || v[:mean] == high
      end
      compared = by_rater.values_at(*extremes).compact.flatten
      residual_spread = (residuals.max - residuals.min).round(2)
      divergence_score = [ spread, residual_spread ].min

      {
        stable_id: stable_id,
        name: capability_names.dig(stable_id, :name) || "Unknown capability",
        category_name: capability_names.dig(stable_id, :category_name),
        rater_means: rater_means,
        spread: spread,
        residual_spread: residual_spread,
        divergence_score: divergence_score,
        flagged: divergence_score >= DIVERGENCE_FLAG_THRESHOLD && cells.size >= FLAG_MIN_CELLS,
        # A gap between two numbers nobody looked at this cycle isn't a live
        # disagreement — the board still ranks it (the divergence is real in
        # the data), but the row says how much of it is inherited.
        carried_count: compared.count { |c| c[:carried] },
        cell_count: compared.size
      }
    end

    rows.sort_by { |row| [ -row[:divergence_score], -row[:spread] ] }
  end

  def capability_names
    @capability_names ||= FrameworkState::Capability
      .joins(:category)
      .where(framework_capability_categories: { framework_id: @session.framework_id })
      .pluck(:stable_id, "framework_capabilities.name", "framework_capability_categories.name")
      .to_h { |stable_id, name, category| [ stable_id, { name: name, category_name: category } ] }
  end

  def mean(values)
    return nil if values.empty?

    (values.sum.to_f / values.size).round(2)
  end
end
