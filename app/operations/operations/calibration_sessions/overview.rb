# frozen_string_literal: true

# The calibration overview for one session: readiness as cell coverage
# (per rater and for the population), the rater tendency strip (mean vs org,
# rating distribution, self-gap, evidence backing), the
# capability divergence board ranked by tendency-corrected disagreement,
# and the people grouped by assessed level (per-person % of expected, manager-only — the
# assessment's own number). "Where are my raters most inconsistent?" and
# "who is rated high or low against their level peers?" as data.
class Operations::CalibrationSessions::Overview < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Calibration overview for a session — readiness per rater and for the whole population (readiness.reference groups people whose rater is not in the session), as fractions of cell_total, the at-level cells: coverage_pct rated, carried_pct carried from last cycle and not yet confirmed, evidence_coverage_pct with at least one active evidence link, and ready_state (ready | to_confirm | unrated | no_cells); per-rater tendency (mean vs org, distribution, self-gap; evidence_pct is the backed share of RATED cells), capabilities ranked by tendency-corrected rater disagreement, and people grouped by assessed level, each with a per-person % of expected (100 = meeting the level, 200 = demonstrating the next level in full; manager ratings only; a coverage-gated person carries pct: null with rated/total/unlock_target — not rated yet, never a low score)."
  category :read
  approval :none

  parameter :session_id, String, required: true

  def policy_check
    authorize session, :show?
  end

  # @return [Hash] `{ session_id, org_mean, raters: [...], capabilities: [...],
  #   readiness: {...}, cohorts: [...] }` with person/capability names resolved for direct
  #   consumption. Cohort dots carry the coverage gate verbatim (`pct` nil,
  #   `rated`/`total`/`unlock_target` when gated) and the carried
  #   disclosure — an agent must never read a gated person as low-scoring.
  def perform
    stats = CalibrationSessions::OverviewStats.new(session: session).call
    cohorts = CalibrationSessions::CohortScores.new(session: session).call[:cohorts]
    readiness = stats[:readiness]
    people = stats[:raters].map { |r| r[:participant_id] } +
             readiness[:reference].filter_map { |row| row[:rater_id] } +
             cohorts.flat_map { |c| c[:people].map { |dot| dot[:person_id] } }
    names = Person.where(id: people.uniq).pluck(:id, :name).to_h

    {
      session_id: session.id,
      status: session.status,
      org_mean: stats[:org_mean],
      raters: stats[:raters].map { |row| row.merge(name: names[row[:participant_id]]) },
      capabilities: stats[:capabilities],
      insufficient_capability_count: stats[:insufficient_capability_count],
      readiness: readiness.merge(
        reference: readiness[:reference].map { |row| row.merge(name: names[row[:rater_id]]) }
      ),
      cohorts: cohorts.map do |cohort|
        cohort.merge(people: cohort[:people].map { |dot| dot.merge(name: names[dot[:person_id]]) })
      end
    }
  end
end
