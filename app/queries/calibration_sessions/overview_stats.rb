# frozen_string_literal: true

# Assembles the calibration overview for one session: the rater tendency
# strip and the capability divergence board
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
# same recorded-manager/delegation semantics as the seed) contribute —
# reference people whose rater isn't in the room are excluded from
# tendency statistics by design (you can't calibrate someone in
# absentia).
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
  # stats. Deliberately NOT PersonDevelopment::Scoring's weights
  # (0/0.25/0.5/1.0) — calibration compares raters on an ordinal scale,
  # not scoring contribution.
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
  def initialize(session:)
    @session = session
  end

  # @return [Hash] `{ org_mean:, raters: [...], capabilities: [...], insufficient_capability_count: }`
  #   Raters: `{ participant_id:, report_count:, rated_count:, cell_count:, mean:,
  #   org_delta:, distribution: {frequency => count}, self_gap:, evidence_pct:,
  #   carried_count:, small_n: }` — `carried_count` counts this rater's cells
  #   seeded from a prior cycle, out of `cell_count`.
  #   Capabilities (sorted most-divergent first): `{ stable_id:, name:, category_name:,
  #   rater_means: {participant_id => {mean:, n:}}, spread:, residual_spread:,
  #   divergence_score:, flagged:, carried_count:, cell_count: }` — here
  #   `cell_count`/`carried_count` cover ONLY the raters sitting at the two
  #   means that define `spread`, so the pair describes the comparison on
  #   screen (they are NOT the capability's whole cell set).
  #
  #   Both row shapes are part of the `calibration_sessions_overview` MCP
  #   response (Operations::CalibrationSessions::Overview passes them
  #   through), so additions here are a client-visible contract change.
  def call
    @call ||= build
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
      insufficient_capability_count: @insufficient_capability_count || 0
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
    @rater_for ||= CalibrationSessions::PopulationSeeds.new(
      framework_id: @session.framework_id,
      participant_ids: participant_ids,
      facilitator_id: @session.facilitator_id
    ).attribution.slice(*calibrant_ids)
  end

  # person_id => assessed level ordinal (cycle enrollment snapshot).
  def assessed_ordinals
    @assessed_ordinals ||= AssessmentCycleEnrollment.active
      .where(cycle_id: @session.cycle_id, person_id: rater_for.keys)
      .pluck(:person_id, :level_ordinal).to_h
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
    @rated_cells ||= AssessmentLevelRating
      .for_cycle(@session.cycle_id)
      .where(person_id: rater_for.keys)
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
          rater_id: rater_for.fetch(person_id),
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
        cell_count: cells.size,
        mean: rater_mean,
        org_delta: rater_mean && org_mean ? (rater_mean - org_mean).round(2) : nil,
        distribution: FREQUENCY_VALUES.keys.index_with { |f| cells.count { |c| c[:frequency] == f } },
        self_gap: gaps.any? ? mean(gaps) : nil,
        evidence_pct: evidence_pct(cells),
        # How much of this rater's tendency is inherited rather than vetted
        # this cycle. Disclosure only: a carried rating is still the rater's
        # rating, so this NEVER softens the tendency it reports — it tells
        # the room the owner has work to do confirming it.
        carried_count: cells.count { |c| c[:carried] },
        small_n: cells.size < SMALL_N
      }
    end
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
        .where(link_status: "active", framework_id: @session.framework_id, person_id: rater_for.keys)
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
