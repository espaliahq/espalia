# frozen_string_literal: true

# Per-person overall scores for a calibration session, grouped into level
# cohorts — "who is being rated higher and lower than their peers at the
# same level, and by whom" (docs/architecture/calibration-sessions.md →
# "Score by cohort").
#
# The metric is the assessment hero's own number: `% of expected`
# (Scoring#performance_ratio), computed at `perspective: :manager_only` so
# the room compares exactly the judgments being calibrated — and so the
# number here can never disagree with the person's assessment. Manager-only
# also keeps self-ratings out entirely, which sidesteps the AssesseeVisibility
# gate: nothing this query returns is the assessee's own private input.
#
# Honesty guards, both deliberate:
# - **Coverage gate** (the hero's rule): below COVERAGE_UNLOCK of at-level
#   cells rated, no score — "4 of 12 rated" is shown instead of a
#   misleadingly low number. Carried values COUNT toward coverage: they are
#   real ratings (marking never softens); LevelCoverage's exclusion of
#   seeded values measures work-state ("vetted this cycle"), a different
#   question from "is this score computed from data".
# - **Carried disclosure**: a dot whose rated cells are mostly inherited is
#   marked, never suppressed.
class CalibrationSessions::CohortScores
  # Fraction of at-level cells that must carry a manager rating before a
  # score shows — the assessment hero's own unlock threshold, so the two
  # gates can never drift apart.
  COVERAGE_UNLOCK = Views::Assessments::HeroSummary::COVERAGE_UNLOCK_THRESHOLD

  # How many capability contributions the why-panel lists per direction.
  WEAKEST_LIMIT = 3
  STRONGEST_LIMIT = 2

  # @param session [CalibrationSession]
  # @param population_seeds [CalibrationSessions::PopulationSeeds, nil]
  #   pass the request's existing instance so the attribution queries run
  #   once per render, not once per consumer
  def initialize(session:, population_seeds: nil)
    @session = session
    @population_seeds = population_seeds
  end

  # @return [Hash] `{ cohorts: [ { ordinal:, median_pct:, people: [dot] } ] }`
  #   — cohorts sorted by ordinal; dots sorted lowest score first (gated
  #   last), each `{ person_id:, rater_id:, ordinal:, pct:, rated:, total:,
  #   unlock_target:, unlocked:, carried_count:, carried_majority: }`.
  #   `pct` is nil while gated. `median_pct` is over unlocked dots only.
  def call
    @call ||= {
      cohorts: dots.group_by { |dot| dot[:ordinal] }.sort.map do |ordinal, people|
        unlocked = people.select { |dot| dot[:unlocked] }.map { |dot| dot[:pct] }
        {
          ordinal: ordinal,
          median_pct: median(unlocked),
          people: people.sort_by { |dot| [ dot[:unlocked] ? 0 : 1, dot[:pct] || 0 ] }
        }
      end
    }
  end

  # The drill-into-why for one dot: this person's at-level capability
  # contributions, lowest and highest. Built per drawer occupant (the
  # inspector + up to MAX_PINS pins) — one engine walk each, never one
  # per dot.
  #
  # The score each capability shows at this person's own level, on the same
  # 0–200 scale as the axis beside it (#421). It used to be a signed
  # weight-unit delta, which could only be compared against the other rows
  # in the same drawer — and read `-1.0` for every capability nobody had
  # rated at that level, so a column of three often ranked nothing.
  #
  # The split is the score's own arithmetic rather than the sign of a
  # delta: the assessment's number is the weighted mean of these, so a
  # capability below 100% pulls the mean down and one above it pulls up.
  # Same boundary as the old sign test, said in the unit the page uses.
  #
  # Weight rides along because this drawer compares PEOPLE: a ×2 capability
  # at 50% drags twice as hard as a ×1 one, and a percentage alone hides it.
  #
  # @param person_id [String]
  # @return [Hash, nil] `{ weakest: [...], strongest: [...] }`, entries
  #   `{ stable_id:, name:, score:, state:, weight: }`; nil for an unknown
  #   or gated person
  def why_for(person_id)
    dot = dots.find { |d| d[:person_id] == person_id }
    return nil unless dot && dot[:unlocked]

    engine = engine_for(person_id)
    scores = engine.capability_scores_at(dot[:ordinal])
    rows = bindings_for(enrollment[person_id][1]).filter_map do |binding|
      capability = binding.capability
      next unless expectation_cells.include?([ capability.stable_id, dot[:ordinal] ])

      score = scores[capability.stable_id]
      next unless score&.dig(:scorable)

      { stable_id: capability.stable_id, name: capability.name,
        ratio: score[:score], state: score[:state], weight: binding.weight.to_f }
    end.sort_by { |entry| entry[:ratio] }

    {
      weakest: for_display(rows.select { |row| row[:ratio] < 1.0 }.first(WEAKEST_LIMIT)),
      # Strictly above: a capability at exactly 100% is MEETING the level,
      # which is neither "above expectations" (the column's empty copy) nor
      # pulling anything up — listing it green contradicted both.
      strongest: for_display(rows.reverse.select { |row| row[:ratio] > 1.0 }.first(STRONGEST_LIMIT))
    }
  end

  private

  # Rank and partition on the raw ratio, round only what is shown. Rounding
  # first put a capability at 99.6% of expectations on exactly 100, so it
  # fell out of the weakest list — off both columns, in the one view whose
  # job is finding the capability that needs the conversation.
  #
  # @param rows [Array<Hash>] entries carrying a raw `:ratio`
  # @return [Array<Hash>] the same entries with `:score` as whole percent
  def for_display(rows)
    rows.map { |row| row.except(:ratio).merge(score: (row[:ratio] * 100).round(0)) }
  end

  def dots
    @dots ||= enrollment.filter_map do |person_id, (ordinal, role_id)|
      # An enrollment predating the ADR-19 role snapshot can't be scored —
      # but silence would misread as "not in the population". It renders as
      # a gated chip naming the reason instead of vanishing.
      next no_snapshot_dot(person_id, ordinal) unless role_id

      total = eligible_stable_ids(role_id, ordinal).size
      rated, carried = at_level_rated(person_id, role_id, ordinal)
      unlock_target = (total * COVERAGE_UNLOCK).ceil
      # A role with zero at-level cells has nothing to score — gated with
      # total 0, which the view words as "no behaviours at this level"
      # rather than a stuck unlock prompt.
      unlocked = total.positive? && rated >= unlock_target

      {
        person_id: person_id,
        rater_id: rater_for[person_id],
        ordinal: ordinal,
        pct: unlocked ? (engine_for(person_id).performance_ratio * 100).round : nil,
        rated: rated,
        total: total,
        unlock_target: unlock_target,
        unlocked: unlocked,
        carried_count: carried,
        carried_majority: rated.positive? && carried * 2 > rated
      }
    end
  end

  # The un-scorable shape for a pre-snapshot enrollment: gated, zero
  # totals, flagged so the view can word the chip honestly.
  def no_snapshot_dot(person_id, ordinal)
    { person_id: person_id, rater_id: rater_for[person_id], ordinal: ordinal,
      pct: nil, rated: 0, total: 0, unlock_target: 0, unlocked: false,
      carried_count: 0, carried_majority: false, role_missing: true }
  end

  # person_id => [ordinal, role_id] — the ADR-19 cycle snapshot, both halves
  # from one row (the drill-in's rule; frozen once the cycle closes).
  def enrollment
    @enrollment ||= AssessmentCycleEnrollment.active
      .where(cycle_id: @session.cycle_id, person_id: calibrant_ids)
      .where.not(level_ordinal: nil)
      .pluck(:person_id, :level_ordinal, :role_id)
      .to_h { |person_id, ordinal, role_id| [ person_id, [ ordinal, role_id ] ] }
  end

  def calibrant_ids
    @calibrant_ids ||= @session.calibrants.pluck(:person_id)
  end

  # The canonical attribution the strip, board, and drill-in all read.
  def rater_for
    @rater_for ||= (@population_seeds || CalibrationSessions::PopulationSeeds.new(
      framework_id: @session.framework_id,
      participant_ids: @session.participants.pluck(:person_id),
      facilitator_id: @session.facilitator_id
    )).attribution
  end

  # One Scoring engine per person — manager-only, the framework's own
  # thresholds, the same wiring Assessments::MatrixDataBuilder uses.
  # Built lazily: only unlocked dots (and the why-panel's person) ever
  # need one, so gated and pre-snapshot people cost nothing here.
  def engine_for(person_id)
    @engine_for ||= {}
    @engine_for[person_id] ||= begin
      ordinal, role_id = enrollment[person_id]
      PersonDevelopment::Scoring.new(
        level_ratings: ratings_by_person.fetch(person_id, []),
        bindings: bindings_for(role_id),
        categories: categories,
        person_level: ordinal,
        all_level_ordinals: ladder_for(role_id),
        expectation_cells: expectation_cells,
        perspective: :manager_only,
        thresholds: thresholds
      )
    end
  end

  # ALL levels, not just at-level: below-level cells feed the ratio's
  # assumed-consistent default exactly as the assessment hero computes it.
  def ratings_by_person
    @ratings_by_person ||= AssessmentLevelRating
      .for_cycle(@session.cycle_id)
      .where(framework_id: @session.framework_id, person_id: enrollment.keys)
      .group_by(&:person_id)
  end

  # The stable_ids that count for this (role, level): active, bound
  # capabilities with an expectation at the ordinal — the same set Scoring
  # actually scores. Both halves of the coverage fraction read THIS set: a
  # stale rating on an unbound / archived / no-expectation capability must
  # not inflate `rated` past what the score is computed from.
  def eligible_stable_ids(role_id, ordinal)
    @eligible_stable_ids ||= {}
    @eligible_stable_ids[[ role_id, ordinal ]] ||= bindings_for(role_id)
      .map { |binding| binding.capability.stable_id }
      .select { |stable_id| expectation_cells.include?([ stable_id, ordinal ]) }
      .to_set
  end

  # [rated, carried] counts over the person's ELIGIBLE at-level cells.
  # Carried counts as rated (a carried rating is the rater's rating); it is
  # also reported separately so the dot can wear the disclosure.
  def at_level_rated(person_id, role_id, ordinal)
    eligible = eligible_stable_ids(role_id, ordinal)
    rows = ratings_by_person.fetch(person_id, []).select do |rating|
      rating.level_ordinal == ordinal &&
        rating.manager_rated_frequency.present? &&
        eligible.include?(rating.capability_stable_id)
    end
    [ rows.size, rows.count { |rating| rating.manager_rating_source == "seeded" } ]
  end

  def bindings_for(role_id)
    @bindings_for ||= {}
    @bindings_for[role_id] ||= FrameworkState::CapabilityRoleBinding
      .includes(:capability)
      .where(role_id: role_id)
      .select { |binding| binding.capability&.status == "active" }
  end

  def categories
    @categories ||= FrameworkState::CapabilityCategory
      .where(framework_id: @session.framework_id).to_a
  end

  # Every (capability_stable_id, level_ordinal) cell with an expectation in
  # the framework — the coverage denominator AND the engine's band shape,
  # from the one query the assessment hero's numbers rest on.
  def expectation_cells
    @expectation_cells ||= FrameworkState::BehaviouralExpectation.stable_cells(
      FrameworkState::Capability.joins(:category)
        .merge(FrameworkState::CapabilityCategory.where(framework_id: @session.framework_id))
        .pluck(:capability_id)
    )
  end

  # The ROLE's ladder, as the assessment hero scores it — not the framework's
  # union of ordinals. A manager ladder that stops at L7 must read as the top
  # of the ladder here too, and its prior bucket must pool the same levels.
  def ladder_for(role_id)
    @ladder_for ||= {}
    @ladder_for[role_id] ||= FrameworkState::Level.where(role_id: role_id).pluck(:ordinal).sort
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by(framework_id: @session.framework_id)
  end

  def thresholds
    @thresholds ||= framework&.scoring_thresholds || {}
  end

  def median(values)
    return nil if values.empty?

    sorted = values.sort
    middle = sorted.size / 2
    (sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0).round
  end
end
