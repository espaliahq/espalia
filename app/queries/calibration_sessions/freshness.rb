# frozen_string_literal: true

# How fresh a session page's numbers are, and what changed since — the
# cheap read behind the live page's poll
# (docs/architecture/calibration-sessions.md, "Freshness and live refresh").
#
# The stamp is the latest write the readiness card and the overview read:
# the population's ratings this cycle and their evidence. The page renders
# it; the poll asks for it again and, only when it has moved, pays for the
# summary of what moved — so a quiet session costs three `MAX` queries a
# minute per open tab.
#
# Web-only by design: it describes a rendered page's staleness, which an MCP
# client (reading `calibration_sessions_overview` on demand) never has.
class CalibrationSessions::Freshness
  # @param session [CalibrationSession]
  def initialize(session:)
    @session = session
  end

  # @return [Time, nil] the latest write behind the page's numbers
  def stamp
    @stamp ||= [
      # Any rating on a population member this cycle: the poll's job is to
      # notice a write, and the summary below re-reads through the role scope.
      AssessmentLevelRating.for_cycle(@session.cycle_id).where(person_id: calibrant_ids)
        .across_all_roles.maximum(:updated_at),
      EvidenceLink.where(framework_id: @session.framework_id, person_id: calibrant_ids).maximum(:updated_at),
      # A withdrawal changes the item, not its links.
      EvidenceItem.where(framework_id: @session.framework_id, person_id: calibrant_ids).maximum(:updated_at)
    ].compact.max
  end

  # The stamp as it travels to the page and back: microsecond ISO 8601, so
  # two writes in the same second still differ.
  #
  # @return [String, nil]
  def stamp_token
    stamp&.utc&.iso8601(6)
  end

  # @param since [String, nil] a {#stamp_token} the page rendered with
  # @return [Hash] `{ stamp:, changed:, ratings_changed:, evidence_changed:,
  #   by_rater: [{ name:, count: }] }` — the counts cover writes after
  #   `since`; `by_rater` names whose people's at-level ratings moved, most
  #   first, people with no rater in the room under "Other raters"
  def call(since:)
    since_time = parse(since)
    changed = stamp_token != since.presence
    result = { stamp: stamp_token, changed: changed, ratings_changed: 0, evidence_changed: 0, by_rater: [] }
    return result unless changed && since_time

    changed_people = changed_rating_person_ids(since_time)
    result.merge(
      ratings_changed: changed_people.size,
      evidence_changed: EvidenceLink.where(framework_id: @session.framework_id, person_id: calibrant_ids)
        .where("updated_at > ?", since_time).count,
      by_rater: by_rater(changed_people)
    )
  end

  private

  def calibrant_ids
    @calibrant_ids ||= @session.calibrants.pluck(:person_id)
  end

  # One entry per at-level rating written after `since`, as its person_id —
  # the same cells the readiness card counts.
  def changed_rating_person_ids(since_time)
    ordinals = AssessmentCycleEnrollment.active
      .where(cycle_id: @session.cycle_id, person_id: calibrant_ids)
      .pluck(:person_id, :level_ordinal).to_h
    scopes = Assessments::RoleScope.for_people(
      cycle_id: @session.cycle_id, framework_id: @session.framework_id, person_ids: ordinals.keys
    )

    AssessmentLevelRating.for_cycle(@session.cycle_id)
      .within(scopes)
      .where("assessment_level_ratings.updated_at > ?", since_time)
      .pluck(:person_id, :level_ordinal)
      .filter_map { |person_id, ordinal| person_id if ordinals[person_id] == ordinal }
  end

  def by_rater(person_ids)
    return [] if person_ids.empty?

    attribution = CalibrationSessions::PopulationSeeds.new(
      framework_id: @session.framework_id,
      participant_ids: @session.participants.pluck(:person_id),
      facilitator_id: @session.facilitator_id
    ).attribution
    counts = person_ids.map { |person_id| attribution[person_id] }.tally
    names = Person.where(id: counts.keys.compact).pluck(:id, :name).to_h

    counts.map { |rater_id, count| { name: rater_id ? names[rater_id] || "Unknown" : "Other raters", count: count } }
      .sort_by { |row| [ -row[:count], row[:name] ] }
  end

  def parse(token)
    Time.iso8601(token.to_s)
  rescue ArgumentError
    nil
  end
end
