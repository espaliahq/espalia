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
  # score shows — mirrors the assessment hero's unlock threshold.
  COVERAGE_UNLOCK = 0.5

  # How many capability contributions the why-panel lists per direction.
  WEAKEST_LIMIT = 3
  STRONGEST_LIMIT = 2

  # @param session [CalibrationSession]
  def initialize(session:)
    @session = session
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
  # contributions, lowest and highest. Only built for the selected person —
  # the page pays one engine walk, not one per dot.
  #
  # @param person_id [String]
  # @return [Hash, nil] `{ weakest: [...], strongest: [...] }`, entries
  #   `{ stable_id:, name:, delta: }`; nil for an unknown or gated person
  def why_for(person_id)
    dot = dots.find { |d| d[:person_id] == person_id }
    return nil unless dot && dot[:unlocked]

    engine = engines[person_id]
    contributions = bindings_for(enrollment[person_id][1]).filter_map do |binding|
      capability = binding.capability
      next unless expectation_cells.include?([ capability.capability_id, dot[:ordinal] ])

      { stable_id: capability.stable_id, name: capability.name,
        delta: engine.raw_contribution(binding).round(1) }
    end.sort_by { |entry| entry[:delta] }

    {
      weakest: contributions.take_while { |c| c[:delta].negative? }.first(WEAKEST_LIMIT),
      strongest: contributions.reverse.take_while { |c| !c[:delta].negative? }.first(STRONGEST_LIMIT)
    }
  end

  private

  def dots
    @dots ||= enrollment.filter_map do |person_id, (ordinal, role_id)|
      next unless role_id

      total = at_level_total(role_id, ordinal)
      rated, carried = at_level_rated(person_id, ordinal)
      unlock_target = (total * COVERAGE_UNLOCK).ceil
      # A role with zero at-level cells has nothing to score — gated with
      # total 0, which the view words as "no behaviours at this level"
      # rather than a stuck unlock prompt.
      unlocked = total.positive? && rated >= unlock_target

      {
        person_id: person_id,
        rater_id: rater_for[person_id],
        ordinal: ordinal,
        pct: unlocked ? (engines[person_id].performance_ratio * 100).round : nil,
        rated: rated,
        total: total,
        unlock_target: unlock_target,
        unlocked: unlocked,
        carried_count: carried,
        carried_majority: rated.positive? && carried * 2 > rated
      }
    end
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
    @rater_for ||= CalibrationSessions::PopulationSeeds.new(
      framework_id: @session.framework_id,
      participant_ids: @session.participants.pluck(:person_id),
      facilitator_id: @session.facilitator_id
    ).attribution
  end

  # One Scoring engine per person — manager-only, the framework's own
  # thresholds, the same wiring Assessments::MatrixDataBuilder uses.
  def engines
    @engines ||= enrollment.to_h do |person_id, (ordinal, role_id)|
      [ person_id, PersonDevelopment::Scoring.new(
        level_ratings: ratings_by_person.fetch(person_id, []),
        bindings: bindings_for(role_id),
        categories: categories,
        person_level: ordinal,
        all_level_ordinals: all_level_ordinals,
        perspective: :manager_only,
        thresholds: thresholds
      ) ]
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

  def at_level_total(role_id, ordinal)
    bindings_for(role_id).count do |binding|
      expectation_cells.include?([ binding.capability_id, ordinal ])
    end
  end

  # [rated, carried] counts over the person's at-level cells. Carried
  # counts as rated (a carried rating is the rater's rating); it is also
  # reported separately so the dot can wear the disclosure.
  def at_level_rated(person_id, ordinal)
    rows = ratings_by_person.fetch(person_id, []).select do |rating|
      rating.level_ordinal == ordinal && rating.manager_rated_frequency.present?
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

  def expectation_cells
    @expectation_cells ||= FrameworkState::BehaviouralExpectation
      .joins(capability: :category)
      .merge(FrameworkState::CapabilityCategory.where(framework_id: @session.framework_id))
      .pluck(:capability_id, :level_ordinal).to_set
  end

  def all_level_ordinals
    @all_level_ordinals ||= FrameworkState::Level
      .joins(role: :role_family)
      .where(framework_role_families: { framework_id: @session.framework_id })
      .distinct.pluck(:ordinal).sort
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by(framework_id: @session.framework_id)
  end

  def thresholds
    @thresholds ||= {
      mastery_threshold: framework&.mastery_threshold&.to_f,
      meeting_expectation_threshold: framework&.meeting_expectation_threshold&.to_f,
      underperforming_threshold: framework&.underperforming_threshold&.to_f,
      overperformance_cap: framework&.overperformance_cap,
      deficit_threshold: framework&.deficit_threshold&.to_f
    }
  end

  def median(values)
    return nil if values.empty?

    sorted = values.sort
    middle = sorted.size / 2
    (sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0).round
  end
end
