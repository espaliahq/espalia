# frozen_string_literal: true

# Assembles the session-log side panel's data: outcome events off the
# session stream, joined at read time to the framework clarification each
# flag raised and to the ratings read model for revisit resolution (a
# manager rating recorded after the ask = acted on).
#
# Shared because the log is a SIDE PANEL rendered on both the session page
# and the capability drill-in — the room raises an outcome on the drill-in
# and watches it land without leaving the context they're discussing.
module CalibrationSessions::SessionLogData
  extend ActiveSupport::Concern

  private

  # @param session [CalibrationSession]
  # @return [Hash, nil] nil while draft — a draft session has no outcomes
  def session_log_data(session)
    return nil if session.draft?

    outcomes = CalibrationSessions::SessionOutcomes.new(session: session)
    flags = outcomes.flags
    revisits = outcomes.revisit_requests

    {
      # One reverse-chronological feed — the log renders in the product's
      # activity-panel form, not split by outcome type.
      entries: outcomes.entries,
      suggestions: FrameworkState::SuggestedEdit
        .where(suggestion_id: flags.filter_map { |f| f[:suggestion_id] }).index_by(&:suggestion_id),
      capability_names: session_log_capability_names(session, outcomes.entries),
      acted: acted_revisit_cells(session, revisits)
    }
  end

  def session_log_capability_names(session, entries)
    stable_ids = entries.filter_map { |entry| entry[:capability_stable_id] }.uniq
    return {} if stable_ids.empty?

    FrameworkState::Capability
      .joins(:category)
      .where(framework_capability_categories: { framework_id: session.framework_id },
             stable_id: stable_ids)
      .pluck(:stable_id, :name).to_h
  end

  # Set of [person_id, capability_stable_id, level_ordinal] whose manager
  # rating changed after the revisit was requested — rating-change-based
  # resolution, so requests from any number of sessions settle at once.
  def acted_revisit_cells(session, revisits)
    return Set.new if revisits.empty?

    # Scoped to the SESSION's cycle: rating rows are one-per-cycle for the
    # same cell, and only a rating change in this cycle answers this ask —
    # a prior cycle's stale row or a later cycle's seeded carry-forward
    # (which also stamps last_manager_rated_at) must not decide it.
    ratings = AssessmentLevelRating.where(
      cycle_id: session.cycle_id,
      framework_id: session.framework_id,
      person_id: revisits.map { |r| r[:person_id] }.uniq,
      capability_stable_id: revisits.map { |r| r[:capability_stable_id] }.uniq
    ).pluck(:person_id, :capability_stable_id, :level_ordinal, :last_manager_rated_at)
      .to_h { |pid, sid, lo, at| [ [ pid, sid, lo ], at ] }

    revisits.each_with_object(Set.new) do |revisit, acted|
      key = [ revisit[:person_id], revisit[:capability_stable_id], revisit[:level_ordinal] ]
      rated_at = ratings[key]
      acted << key if rated_at && revisit[:requested_at] && rated_at > revisit[:requested_at]
    end
  end

  # Every person a session-log entry names, so the people map covers them.
  def log_person_ids(session_log)
    return [] unless session_log

    session_log[:entries].flat_map do |row|
      [ row[:actor_id], row[:rater_id], row[:person_id] ]
    end.compact.uniq
  end
end
