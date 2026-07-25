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
#   each rater's overall tendency offset. A capability still divergent
#   after the correction is an "unclear expectation" candidate; one
#   whose spread collapses was mostly rater tendency.
class CalibrationSessions::OverviewStats
  FREQUENCY_VALUES = {
    "none" => 0.0, "some" => 1.0, "occasional" => 2.0, "consistent" => 3.0
  }.freeze

  # Raters with fewer rated cells than this are shown with their n but
  # never badged — small samples always look extreme.
  SMALL_N = 3

  # Residual spread (in rating bands) at or above which a capability is
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
  #   org_delta:, distribution: {frequency => count}, self_gap:, evidence_pct:, small_n: }`
  #   Capabilities (sorted most-divergent first): `{ stable_id:, name:, category_name:,
  #   rater_means: {participant_id => {mean:, n:}}, spread:, residual_spread:, flagged: }`
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
    @rater_for ||= CalibrationSessions::PopulationSeeds.new(
      framework_id: @session.framework_id,
      participant_ids: participant_ids,
      facilitator_id: @session.facilitator_id
    ).call.each_with_object({}) do |(participant_id, people), map|
      (people.map(&:id) & calibrant_ids).each { |person_id| map[person_id] = participant_id }
    end
  end

  # person_id => assessed level ordinal (cycle enrollment snapshot).
  def assessed_ordinals
    @assessed_ordinals ||= AssessmentCycleEnrollment.active
      .where(cycle_id: @session.cycle_id, person_id: rater_for.keys)
      .pluck(:person_id, :level_ordinal).to_h
  end

  # One entry per manager-rated at-level cell:
  # { person_id:, rater_id:, capability_stable_id:, frequency:, value:, self_value: }
  def rated_cells
    @rated_cells ||= begin
      rows = AssessmentLevelRating
        .for_cycle(@session.cycle_id)
        .where(person_id: rater_for.keys)
        .where.not(manager_rated_frequency: nil)
      rows.filter_map do |row|
        ordinal = assessed_ordinals[row.person_id]
        next unless ordinal && row.level_ordinal == ordinal

        {
          person_id: row.person_id,
          rater_id: rater_for.fetch(row.person_id),
          capability_stable_id: row.capability_stable_id,
          frequency: row.manager_rated_frequency,
          value: FREQUENCY_VALUES.fetch(row.manager_rated_frequency),
          self_value: row.self_rated_frequency && FREQUENCY_VALUES.fetch(row.self_rated_frequency)
        }
      end
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
      residual_spread = (residuals.max - residuals.min).round(2)

      {
        stable_id: stable_id,
        name: capability_names.dig(stable_id, :name) || "Unknown capability",
        category_name: capability_names.dig(stable_id, :category_name),
        rater_means: rater_means,
        spread: spread,
        residual_spread: residual_spread,
        flagged: residual_spread >= DIVERGENCE_FLAG_THRESHOLD && cells.size >= FLAG_MIN_CELLS
      }
    end

    rows.sort_by { |row| -row[:residual_spread] }
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
