# frozen_string_literal: true

# The calibration overview for one session: the rater tendency strip
# (mean vs org, rating distribution, self-gap, evidence backing) and the
# capability divergence board ranked by tendency-corrected disagreement.
# "Where are my raters most inconsistent?" as data.
class Operations::CalibrationSessions::Overview < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Calibration overview for a session — per-rater tendency (mean vs org, distribution, self-gap, evidence backing) and capabilities ranked by tendency-corrected rater disagreement."
  category :read
  approval :none

  parameter :session_id, String, required: true

  def policy_check
    authorize session, :show?
  end

  # @return [Hash] `{ session_id, org_mean, raters: [...], capabilities: [...] }`
  #   with person/capability names resolved for direct consumption.
  def perform
    stats = CalibrationSessions::OverviewStats.new(session: session).call
    names = Person.where(id: stats[:raters].map { |r| r[:participant_id] })
      .pluck(:id, :name).to_h

    {
      session_id: session.id,
      status: session.status,
      org_mean: stats[:org_mean],
      raters: stats[:raters].map { |row| row.merge(name: names[row[:participant_id]]) },
      capabilities: stats[:capabilities],
      insufficient_capability_count: stats[:insufficient_capability_count]
    }
  end
end
