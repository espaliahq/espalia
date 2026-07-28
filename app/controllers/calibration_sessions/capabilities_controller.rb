# frozen_string_literal: true

# The calibration capability drill-in: expectation text per level beside
# the rater × level dot grid, with a per-person card (ratings + linked
# feedback / evidence) when a dot is opened. Facilitator-only, like every
# session surface (v1). Opening a dot (`?person=`) IS the reveal gesture —
# the client-side choreography keys off that param
# (docs/architecture/calibration-sessions.md, "Anonymization").
class CalibrationSessions::CapabilitiesController < ApplicationController
  # GET /calibration_sessions/:calibration_session_id/capabilities/:id
  def show
    @session = CalibrationSession.find(params.expect(:calibration_session_id))
    authorize @session, :show?, policy_class: CalibrationSessionPolicy

    stats = CalibrationSessions::DrillInStats.new(
      session: @session, capability_stable_id: params.expect(:id)
    ).call
    if stats.nil?
      redirect_to calibration_session_path(@session), alert: "Capability not found in this framework."
      return
    end

    cards = CalibrationSessions::PersonCard.new(
      session: @session, stats: stats, capability_stable_id: params.expect(:id)
    )

    render Views::CalibrationSessions::DrillInView.new(
      session: @session,
      stats: stats,
      people: Person.where(id: stats[:rows].map { |r| r[:rater_id] }.compact).index_by(&:id),
      person_card: cards.for(params[:person].presence),
      can_flag: @session.started? && policy(@session).flag_expectation?,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  end

  private

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
