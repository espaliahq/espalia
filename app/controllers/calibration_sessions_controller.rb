# frozen_string_literal: true

# Calibration sessions — facilitator-run forums for comparing how a set
# of raters rate their reports. V1 is facilitator-only: only the
# facilitator (or a tenant admin) can open the session surfaces; the
# room views a projected screen. See
# docs/architecture/calibration-sessions.md.
#
# Writes dispatch through the shared Operations::CalibrationSessions
# classes so web and MCP behave identically.
#
class CalibrationSessionsController < ApplicationController
  before_action :set_session, only: [ :show ]

  # GET /calibration_sessions
  def index
    authorize CalibrationSession, :index?

    sessions = visible_sessions.order(created_at: :desc).to_a
    cycles = AssessmentCycle.where(cycle_id: sessions.map(&:cycle_id)).index_by(&:cycle_id)
    member_counts = CalibrationSessionMember
      .where(session_id: sessions.map(&:id))
      .group(:session_id, :member_type)
      .count

    render Views::CalibrationSessions::IndexView.new(
      sessions: sessions,
      cycles: cycles,
      member_counts: member_counts,
      can_define: policy(CalibrationSession).define?,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  # GET /calibration_sessions/new
  def new
    authorize CalibrationSession, :define?

    render Views::CalibrationSessions::NewView.new(
      open_cycles: AssessmentCycle.open_cycles.order(opened_at: :desc).to_a,
      participant_suggestions: candidates_query.suggestions,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  # GET /calibration_sessions/participant_candidates
  #
  # Typeahead results for the participant picker. Managers only, scoped
  # like the assessment-cycle reports: tenant-wide for admins, the
  # viewer's own subtree for a manager (enforced in the query, not the
  # client).
  def participant_candidates
    authorize CalibrationSession, :index?

    render Views::Shared::PersonPickerCandidatesFrame.new(
      frame_id: "participant-candidates",
      entries: candidates_query.search(params[:q]),
      query: params[:q].presence
    ), layout: false
  end

  # POST /calibration_sessions
  def create
    authorize CalibrationSession, :define?
    attrs = params.expect(calibration_session: [ :name, :cycle_id, { participant_ids: [] } ])
    participant_ids = Array(attrs[:participant_ids]).reject(&:blank?)
    cycle = AssessmentCycle.find_by(cycle_id: attrs[:cycle_id])

    seeds = cycle && CalibrationSessions::PopulationSeeds.new(
      framework_id: cycle.framework_id,
      participant_ids: participant_ids,
      facilitator_id: current_person&.id
    )

    result = Operations::CalibrationSessions::Define.call(
      context: pundit_user,
      params: {
        cycle_id: attrs[:cycle_id],
        name: attrs[:name],
        participant_ids: participant_ids,
        calibrant_person_ids: seeds ? seeds.person_ids : []
      }
    )

    redirect_to calibration_session_path(result[:session_id]),
                notice: "Calibration session created — curate the population, then start the session."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to new_calibration_session_path, alert: e.message
  end

  # GET /calibration_sessions/:id
  def show
    authorize @session

    members = @session.members.to_a
    participant_ids = members.select { |m| m.member_type == "participant" }.map(&:person_id)
    calibrant_ids = members.select { |m| m.member_type == "calibrant" }.map(&:person_id)
    seed_groups = seed_groups_for(participant_ids)
    session_log = session_log_data

    people_ids = (participant_ids + calibrant_ids + [ @session.facilitator_id ] +
                  log_person_ids(session_log)).uniq

    render Views::CalibrationSessions::ShowView.new(
      session: @session,
      cycle: AssessmentCycle.find_by(cycle_id: @session.cycle_id),
      people: Person.where(id: people_ids).index_by(&:id),
      participant_ids: participant_ids,
      calibrant_ids: calibrant_ids,
      groups: population_groups(seed_groups, calibrant_ids),
      suggestions: suggested_additions(seed_groups, calibrant_ids, participant_ids),
      readiness: readiness_for(calibrant_ids),
      stats: participant_ids.any? ? CalibrationSessions::OverviewStats.new(session: @session).call : nil,
      add_calibrant_candidates: @session.draft? ? add_calibrant_candidates(calibrant_ids, participant_ids) : [],
      can_curate: @session.draft? && policy(@session).curate?,
      can_start: @session.draft? && policy(@session).start?,
      can_close: !@session.closed? && policy(@session).close?,
      session_log: session_log,
      can_note: @session.started? && policy(@session).flag_expectation?,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  private

  def set_session
    @session = CalibrationSession.find(params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  end

  # The session-log data for the follow-through section: outcome events off
  # the session stream, joined at read time to the framework clarification
  # each flag raised and to the ratings read model for revisit resolution
  # (a manager rating recorded after the ask = acted on). nil while draft —
  # a draft session has no outcomes.
  def session_log_data
    return nil if @session.draft?

    outcomes = CalibrationSessions::SessionOutcomes.new(session: @session)
    flags = outcomes.flags
    revisits = outcomes.revisit_requests
    notes = outcomes.notes

    {
      # One reverse-chronological feed — the log renders in the product's
      # activity-panel form, not split by outcome type.
      entries: outcomes.entries,
      suggestions: FrameworkState::SuggestedEdit
        .where(suggestion_id: flags.filter_map { |f| f[:suggestion_id] }).index_by(&:suggestion_id),
      capability_names: session_log_capability_names(flags, revisits, notes),
      acted: acted_revisit_cells(revisits)
    }
  end

  def session_log_capability_names(*outcome_lists)
    stable_ids = outcome_lists.flatten.filter_map { |o| o[:capability_stable_id] }.uniq
    return {} if stable_ids.empty?

    FrameworkState::Capability
      .joins(:category)
      .where(framework_capability_categories: { framework_id: @session.framework_id },
             stable_id: stable_ids)
      .pluck(:stable_id, :name).to_h
  end

  # Set of [person_id, capability_stable_id, level_ordinal] whose manager
  # rating changed after the revisit was requested — rating-change-based
  # resolution, so requests from any number of sessions settle at once.
  def acted_revisit_cells(revisits)
    return Set.new if revisits.empty?

    # Scoped to the SESSION's cycle: rating rows are one-per-cycle for the
    # same cell, and only a rating change in this cycle answers this ask —
    # a prior cycle's stale row or a later cycle's seeded carry-forward
    # (which also stamps last_manager_rated_at) must not decide it.
    ratings = AssessmentLevelRating.where(
      cycle_id: @session.cycle_id,
      framework_id: @session.framework_id,
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

  # Every person a session-log row names, so the people map covers them.
  def log_person_ids(session_log)
    return [] unless session_log

    (session_log[:flags] + session_log[:revisits] + session_log[:notes]).flat_map do |row|
      [ row[:flagged_by_id], row[:requested_by_id], row[:recorded_by_id],
        row[:rater_id], row[:person_id] ]
    end.compact.uniq
  end

  # The AuthorizationContext predicate, so the visibility scoping here can't
  # drift from what CalibrationSessionPolicy grants.
  def admin_viewer?
    pundit_user.tenant_admin?
  end

  def visible_sessions
    return CalibrationSession.all if admin_viewer?

    CalibrationSession.where(facilitator_id: current_person&.id)
  end

  # Shared scope for the participant picker's search + suggestions.
  def candidates_query
    CalibrationSessions::ParticipantCandidates.new(
      viewer: current_person, admin: admin_viewer?
    )
  end

  # The seed mapping for the CURRENT participants — used to group the
  # population by rater for display and to power "refresh suggestions".
  def seed_groups_for(participant_ids)
    return {} if participant_ids.empty?

    CalibrationSessions::PopulationSeeds.new(
      framework_id: @session.framework_id,
      participant_ids: participant_ids,
      facilitator_id: @session.facilitator_id
    ).call
  end

  # Buckets the current population by rater: [[participant_id, member_ids]],
  # plus an "other" bucket for calibrants no current participant rates
  # (added individually / rater not in session).
  def population_groups(seed_groups, calibrant_ids)
    remaining = calibrant_ids.dup
    groups = seed_groups.map do |participant_id, people|
      ids = people.map(&:id) & calibrant_ids
      remaining -= ids
      [ participant_id, ids ]
    end
    groups << [ nil, remaining ] if remaining.any?
    groups
  end

  # People the seed query would include today but who aren't in the
  # population — surfaced as explicit "add?" suggestions, never silently
  # merged (curated list rule).
  def suggested_additions(seed_groups, calibrant_ids, participant_ids)
    return [] unless @session.draft?

    seed_groups.values.flatten.uniq(&:id)
      .reject { |p| calibrant_ids.include?(p.id) || participant_ids.include?(p.id) }
  end

  # Enrollment + manager-rating readiness for the population on the
  # session's cycle. Per-person flags drive badges; counts drive the bar.
  # partially_rated_ids distinguishes "the manager has touched some cells"
  # (In progress) from untouched — manager_completed_at only stamps at
  # FULL current-level VETTED coverage (carried/seeded values don't
  # count; see Assessments::LevelCoverage). carried_only_ids marks
  # managers whose values exist but are entirely carried forward —
  # rendered "To confirm", matching the /assessments list vocabulary.
  def readiness_for(calibrant_ids)
    if calibrant_ids.empty?
      return { enrolled_ids: [], manager_complete_ids: [], partially_rated_ids: [], carried_only_ids: [] }
    end

    human_touched = AssessmentLevelRating
      .for_cycle(@session.cycle_id)
      .where(person_id: calibrant_ids)
      .where(
        "manager_rating_source = 'human' " \
        "OR (manager_rated_frequency IS NOT NULL AND manager_rating_source IS NULL)"
      )
      .distinct.pluck(:person_id)
    any_rated = AssessmentLevelRating
      .for_cycle(@session.cycle_id)
      .where(person_id: calibrant_ids)
      .where.not(manager_rated_frequency: nil)
      .distinct.pluck(:person_id)

    {
      enrolled_ids: AssessmentCycleEnrollment.active
        .where(cycle_id: @session.cycle_id, person_id: calibrant_ids).pluck(:person_id),
      manager_complete_ids: AssessmentCycleProgress
        .where(cycle_id: @session.cycle_id, person_id: calibrant_ids)
        .where.not(manager_completed_at: nil).pluck(:person_id),
      partially_rated_ids: human_touched,
      carried_only_ids: any_rated - human_touched
    }
  end

  def add_calibrant_candidates(calibrant_ids, participant_ids)
    excluded = calibrant_ids + participant_ids + [ @session.facilitator_id ]
    scope =
      if admin_viewer?
        Person.where.not(id: excluded)
      else
        facilitator = Person.find_by(id: @session.facilitator_id)
        return [] unless facilitator

        facilitator.all_reports.where.not(id: excluded)
      end
    scope.order(:name).limit(200).to_a
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
