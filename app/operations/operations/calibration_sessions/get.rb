# frozen_string_literal: true

# One calibration session's full detail — lifecycle state plus the
# participant and calibrant rosters (id + name, per the incremental
# disclosure rule; drill deeper via the assessment tools).
class Operations::CalibrationSessions::Get < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Get one calibration session — lifecycle state plus participant and calibrant rosters."
  category :read
  approval :none

  parameter :session_id, String, required: true

  def policy_check
    authorize session, :show?
  end

  # @return [Hash] session detail with `participants` / `calibrants` rosters
  def perform
    members = session.members.to_a
    names = Person.where(id: members.map(&:person_id)).pluck(:id, :name).to_h

    {
      session_id: session.id,
      cycle_id: session.cycle_id,
      framework_id: session.framework_id,
      framework_version: session.framework_version,
      name: session.name,
      status: session.status,
      facilitator_id: session.facilitator_id,
      defined_by: session.defined_by,
      started_at: session.started_at,
      closed_at: session.closed_at,
      close_reason: session.close_reason,
      participants: roster(members, "participant", names),
      calibrants: roster(members, "calibrant", names)
    }
  end

  private

  def roster(members, member_type, names)
    members
      .select { |m| m.member_type == member_type }
      .sort_by { |m| names[m.person_id].to_s }
      .map { |m| { person_id: m.person_id, name: names[m.person_id] } }
  end
end
