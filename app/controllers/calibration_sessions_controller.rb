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
      participant_candidates: participant_candidates,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
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

    render Views::CalibrationSessions::ShowView.new(
      session: @session,
      cycle: AssessmentCycle.find_by(cycle_id: @session.cycle_id),
      people: Person.where(id: (participant_ids + calibrant_ids + [ @session.facilitator_id ]).uniq).index_by(&:id),
      participant_ids: participant_ids,
      calibrant_ids: calibrant_ids,
      groups: population_groups(seed_groups, calibrant_ids),
      suggestions: suggested_additions(seed_groups, calibrant_ids, participant_ids),
      readiness: readiness_for(calibrant_ids),
      add_calibrant_candidates: @session.draft? ? add_calibrant_candidates(calibrant_ids, participant_ids) : [],
      add_participant_candidates: @session.draft? ? add_participant_candidates(participant_ids) : [],
      can_curate: @session.draft? && policy(@session).curate?,
      can_start: @session.draft? && policy(@session).start?,
      can_close: !@session.closed? && policy(@session).close?,
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

  def admin_viewer?
    current_user&.global_admin? || current_tenant_user&.admin? || false
  end

  def visible_sessions
    return CalibrationSession.all if admin_viewer?

    CalibrationSession.where(facilitator_id: current_person&.id)
  end

  # Managers the caller may pick as participants: managers within their
  # subtree (themselves included when they directly manage people), or
  # every manager in the tenant for admins.
  def participant_candidates
    manager_ids = Person.where.not(manager_id: nil).distinct.pluck(:manager_id)
    scope =
      if admin_viewer?
        Person.where(id: manager_ids)
      else
        in_scope = current_person.all_reports.pluck(:id) + [ current_person.id ]
        Person.where(id: manager_ids & in_scope)
      end
    scope.order(:name).to_a
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
  def readiness_for(calibrant_ids)
    return { enrolled_ids: [], manager_complete_ids: [] } if calibrant_ids.empty?

    {
      enrolled_ids: AssessmentCycleEnrollment.active
        .where(cycle_id: @session.cycle_id, person_id: calibrant_ids).pluck(:person_id),
      manager_complete_ids: AssessmentCycleProgress
        .where(cycle_id: @session.cycle_id, person_id: calibrant_ids)
        .where.not(manager_completed_at: nil).pluck(:person_id)
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

  def add_participant_candidates(participant_ids)
    participant_candidates.reject { |p| participant_ids.include?(p.id) }
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
