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

    render Views::CalibrationSessions::DrillInView.new(
      session: @session,
      stats: stats,
      people: Person.where(id: stats[:rows].map { |r| r[:rater_id] }.compact).index_by(&:id),
      person_card: person_card(stats),
      can_flag: @session.started? && policy(@session).flag_expectation?,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  end

  private

  # Card data for the opened dot: the member's at-level ratings plus the
  # active feedback / evidence linked to this capability at their level.
  def person_card(stats)
    person_id = params[:person].presence
    return nil unless person_id

    dot = stats[:rows].flat_map { |row| row[:people].values.flatten }
      .find { |d| d[:person_id] == person_id }
    return nil unless dot

    row = stats[:rows].find { |r| r[:people].values.flatten.any? { |d| d[:person_id] == person_id } }
    ordinal = stats[:rows].flat_map { |r| r[:people].to_a }
      .find { |_, dots| dots.any? { |d| d[:person_id] == person_id } }&.first

    {
      dot: dot,
      ordinal: ordinal,
      rater_id: row&.dig(:rater_id),
      evidence: evidence_for(person_id, ordinal)
    }
  end

  def evidence_for(person_id, ordinal)
    links = EvidenceLink.where(
      link_status: "active", framework_id: @session.framework_id,
      capability_stable_id: params[:id], person_id: person_id, level_ordinal: ordinal
    ).pluck(:evidence_id, :valence).to_h

    EvidenceItem.active.where(id: links.keys).order(recorded_at: :desc).map do |item|
      {
        content: item.content,
        valence: links[item.id],
        author_id: item.author_id,
        relation: author_relation(item.author_id, person_id),
        recorded_at: item.recorded_at
      }
    end
  end

  # Relation-first authorship for the projected room — names stay off the
  # card by default (the facilitator can open the full assessment when
  # authorship genuinely matters). See the design doc's evidence rules.
  def author_relation(author_id, person_id)
    return "self" if author_id == person_id

    manager_id = RecordedReportingManager.manager_id_for(person_id, @session.framework_id) ||
                 Person.find_by(id: person_id)&.manager_id
    author_id == manager_id ? "manager" : "peer"
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
