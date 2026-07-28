# frozen_string_literal: true

# Lists calibration sessions visible to the caller — sessions they
# facilitate, or every session in the tenant for admins. Optionally
# narrowed to one assessment cycle.
class Operations::CalibrationSessions::List < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "List calibration sessions you facilitate (admins see all), optionally filtered to one assessment cycle."
  category :read
  approval :none

  parameter :cycle_id, String

  def policy_check
    authorize CalibrationSession, :index?
  end

  # @return [Hash] `{ sessions: [{ session_id, cycle_id, name, status, ... }] }`
  def perform
    scope = visible_sessions
    if params[:cycle_id]
      ensure_uuid!(:cycle_id, params[:cycle_id])
      scope = scope.for_cycle(params[:cycle_id])
    end

    counts = member_counts(scope)
    {
      sessions: scope.order(created_at: :desc).map do |session|
        {
          session_id: session.id,
          cycle_id: session.cycle_id,
          framework_id: session.framework_id,
          name: session.name,
          status: session.status,
          facilitator_id: session.facilitator_id,
          participant_count: counts.fetch([ session.id, "participant" ], 0),
          calibrant_count: counts.fetch([ session.id, "calibrant" ], 0),
          started_at: session.started_at,
          closed_at: session.closed_at
        }
      end
    }
  end

  private

  def visible_sessions
    return CalibrationSession.all if admin_actor?

    CalibrationSession.where(facilitator_id: context.person&.id)
  end

  def member_counts(scope)
    CalibrationSessionMember
      .where(session_id: scope.select(:id))
      .group(:session_id, :member_type)
      .count
  end
end
