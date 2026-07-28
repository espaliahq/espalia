# frozen_string_literal: true

# The calibration capability drill-in: expectation text per level beside
# the rater × level dot grid, with three bottom-pane views — the per-person
# card (`?person=`), the evidence wall (`?view=wall`), and the compare tray
# (`?view=compare` + `compare[]=` pins). Facilitator-only, like every
# session surface (v1). Opening a dot (`?person=`) IS the reveal gesture,
# and pinning to compare implies discussing implies revealed — the
# client-side choreography keys off these params
# (docs/architecture/calibration-sessions.md, "Anonymization").
class CalibrationSessions::CapabilitiesController < ApplicationController
  # The tray is a deliberate juxtaposition of 2–3 cards, not a dashboard.
  MAX_COMPARE_PINS = 3

  VIEWS = %w[wall compare].freeze

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
      view: view_param,
      wall: (evidence_wall if view_param == "wall"),
      wall_filters: wall_filters,
      compare_ids: compare_ids,
      compare_cards: compare_ids.to_h { |person_id| [ person_id, cards.for(person_id) ] }.compact,
      can_flag: @session.started? && policy(@session).flag_expectation?,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  end

  private

  # @return [String, nil] "wall" / "compare" / nil (person card or nothing)
  def view_param
    params[:view].presence_in(VIEWS)
  end

  # Pinned compare people — capped, deduplicated, and confined to the
  # session's population (a foreign id in the URL renders nothing).
  #
  # @return [Array<String>]
  def compare_ids
    @compare_ids ||= begin
      requested = Array.wrap(params[:compare]).select(&:present?).uniq.first(MAX_COMPARE_PINS)
      requested & @session.calibrants.pluck(:person_id)
    end
  end

  def evidence_wall
    CalibrationSessions::EvidenceWall.new(
      session: @session,
      capability_stable_id: params.expect(:id),
      level: wall_filters[:level],
      valence: wall_filters[:valence],
      rater_id: wall_filters[:rater_id]
    ).call
  end

  # @return [Hash] sanitized wall filters (also echoed into the filter form)
  def wall_filters
    @wall_filters ||= {
      level: params[:wall_level].presence&.to_i,
      valence: params[:wall_valence].presence_in(EvidenceLink::VALENCES),
      rater_id: params[:wall_rater].presence
    }
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
