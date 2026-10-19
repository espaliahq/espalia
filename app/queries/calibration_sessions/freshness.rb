# frozen_string_literal: true

# How fresh a session page's numbers are, and what changed since — the
# cheap read behind the live page's poll
# (docs/architecture/calibration-sessions.md, "Freshness and live refresh").
#
# The stamp is the latest write the readiness card and the overview read:
# the population's ratings this cycle, their evidence, and their enrollments
# (a level or role change moves the denominator). The page renders it; the
# poll asks for it again and, only when it has moved, pays for the summary
# of what moved — so a quiet session costs four `MAX` queries a minute per
# open tab.
#
# Known blind spot: a bulk `update_all` that skips `updated_at` (a framework
# publish re-keying evidence links) moves numbers without moving the stamp.
# Refresh always reloads, so the room has a way out.
#
# Web-only by design: it describes a rendered page's staleness, which an MCP
# client (reading `calibration_sessions_overview` on demand) never has.
class CalibrationSessions::Freshness
  # Which side of a rating moved: each side stamps its own column.
  WRITTEN_SINCE = {
    manager: "assessment_level_ratings.last_manager_rated_at > ?",
    self: "assessment_level_ratings.last_self_rated_at > ?"
  }.freeze

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
      EvidenceItem.where(framework_id: @session.framework_id, person_id: calibrant_ids).maximum(:updated_at),
      AssessmentCycleEnrollment.where(cycle_id: @session.cycle_id, person_id: calibrant_ids).maximum(:updated_at)
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
  # @return [Hash] `{ stamp:, changed:, ratings_changed:, self_ratings_changed:,
  #   evidence_changed:, by_rater: [{ name:, count: }] }` — the counts cover
  #   writes after `since`: at-level MANAGER ratings (credited in `by_rater`
  #   to the rater in the room, most first, "Other raters" otherwise),
  #   at-level self-ratings (credited to nobody — the manager didn't write
  #   them), and feedback / evidence items added, relinked or withdrawn
  def call(since:)
    since_time = parse(since)
    changed = stamp_token != since.presence
    result = { stamp: stamp_token, changed: changed, ratings_changed: 0, self_ratings_changed: 0,
               evidence_changed: 0, by_rater: [] }
    return result unless changed && since_time

    manager_changes = changed_rating_person_ids(since_time, side: :manager)
    result.merge(
      ratings_changed: manager_changes.size,
      self_ratings_changed: changed_rating_person_ids(since_time, side: :self).size,
      evidence_changed: changed_evidence_count(since_time),
      by_rater: by_rater(manager_changes)
    )
  end

  private

  def calibrant_ids
    @calibrant_ids ||= @session.calibrants.pluck(:person_id)
  end

  # One entry per at-level rating whose `side` was written after `since`, as
  # its person_id — the same cells the readiness card counts.
  def changed_rating_person_ids(since_time, side:)
    AssessmentLevelRating.for_cycle(@session.cycle_id)
      .within(role_scopes)
      .where(WRITTEN_SINCE.fetch(side), since_time)
      .pluck(:person_id, :level_ordinal)
      .filter_map { |person_id, ordinal| person_id if assessed_ordinals[person_id] == ordinal }
  end

  # Items whose links or whose own record (a withdrawal) moved.
  def changed_evidence_count(since_time)
    scope = { framework_id: @session.framework_id, person_id: calibrant_ids }
    (EvidenceLink.where(scope).where(EvidenceLink.arel_table[:updated_at].gt(since_time)).pluck(:evidence_id) +
      EvidenceItem.where(scope).where(EvidenceItem.arel_table[:updated_at].gt(since_time)).pluck(:id)).uniq.size
  end

  def assessed_ordinals
    @assessed_ordinals ||= AssessmentCycleEnrollment.active
      .where(cycle_id: @session.cycle_id, person_id: calibrant_ids)
      .pluck(:person_id, :level_ordinal).to_h
  end

  def role_scopes
    @role_scopes ||= Assessments::RoleScope.for_people(
      cycle_id: @session.cycle_id, framework_id: @session.framework_id, person_ids: assessed_ordinals.keys
    )
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
