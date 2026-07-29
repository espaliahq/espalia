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
  include CalibrationSessions::SessionLogData

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

    @cards = CalibrationSessions::PersonCard.new(
      session: @session, stats: stats, capability_stable_id: params.expect(:id)
    )
    compare_cards = resolve_compare_cards(stats)
    # The log rides along as a side panel so an outcome raised here lands
    # in view without leaving the capability under discussion.
    session_log = session_log_data(@session)
    people_ids = (stats[:rows].map { |r| r[:rater_id] } + log_person_ids(session_log)).compact.uniq

    render Views::CalibrationSessions::DrillInView.new(
      session: @session,
      stats: stats,
      people: Person.where(id: people_ids).index_by(&:id),
      session_log: session_log,
      can_note: @session.started? && policy(@session).flag_expectation?,
      person_card: @cards.for(params[:person].presence),
      view: view_param,
      wall: (evidence_wall(stats) if view_param == "wall"),
      wall_filters: wall_filters,
      compare_ids: compare_cards.keys,
      compare_cards: compare_cards,
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

  # Pinned compare cards, keyed by person_id. A pin only survives if it
  # RESOLVES to a card — an id outside the session, or one for someone who
  # has since left the cycle (so they hold no dot on this grid), is dropped
  # rather than becoming a phantom that shows no card, offers no "Unpin",
  # and permanently consumes one of the three slots. Resolve first, cap
  # last, so stale ids ahead of a live one can't squeeze it out.
  #
  # @return [Hash{String => Hash}]
  def resolve_compare_cards(stats)
    requested = Array.wrap(params[:compare]).grep(String).select(&:present?).uniq
    (requested & grid_person_ids(stats))
      .filter_map { |person_id| @cards.for(person_id)&.then { |card| [ person_id, card ] } }
      .first(MAX_COMPARE_PINS).to_h
  end

  # The people the grid actually plots — the wall and the tray share this
  # population so every wall item's reveal gesture (opening that person's
  # dot) is reachable.
  def grid_person_ids(stats)
    @grid_person_ids ||= stats[:rows].flat_map { |row| row[:people].values.flatten }
      .map { |dot| dot[:person_id] }.uniq
  end

  def evidence_wall(stats)
    CalibrationSessions::EvidenceWall.new(
      session: @session,
      capability_stable_id: params.expect(:id),
      person_ids: grid_person_ids(stats),
      level: wall_filters[:level],
      valence: wall_filters[:valence],
      rater_id: wall_filters[:rater_id]
    ).call
  end

  # @return [Hash] sanitized wall filters (also echoed into the filter form)
  def wall_filters
    # Every value is read straight off the query string, so each has to
    # survive an array/hash param without raising (`[…].to_i` is a 500).
    @wall_filters ||= {
      level: params[:wall_level].to_s.presence&.then { |v| v.to_i if v.match?(/\A\d+\z/) },
      valence: params[:wall_valence].presence_in(EvidenceLink::VALENCES),
      rater_id: params[:wall_rater].presence_in(@session.participants.pluck(:person_id))
    }
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
