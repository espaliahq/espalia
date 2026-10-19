# frozen_string_literal: true

# The calibration capability drill-in: the rater × level dot grid (each
# level header carrying its expectation + examples in an ⓘ menu), the
# evidence wall (`?view=wall`), and the comparison drawer — the inspected
# person (`?person=`) plus pinned people (`pins[]=`) side by side.
# Facilitator-only, like every session surface (v1) — see
# docs/architecture/calibration-sessions.md.
class CalibrationSessions::CapabilitiesController < ApplicationController
  include CalibrationSessions::SessionLogData

  MAX_COMPARE_PINS = Views::CalibrationSessions::ComparisonDrawerChrome::MAX_PINS

  VIEWS = %w[wall].freeze

  # The person card's kebab actions — which (single) form renders open.
  PERSON_ACTIONS = %w[request revisit flag].freeze

  # GET /calibration_sessions/:calibration_session_id/capabilities/:id
  def show
    @session = CalibrationSession.find(params.expect(:calibration_session_id))
    authorize @session, :show?, policy_class: CalibrationSessionPolicy

    stats = CalibrationSessions::DrillInStats.new(
      session: @session, capability_stable_id: params.expect(:id),
      visible_person_ids: visible_person_ids
    ).call
    if stats.nil?
      redirect_to calibration_session_path(@session), alert: "Capability not found in this framework."
      return
    end

    outcomes = CalibrationSessions::SessionOutcomes.new(session: @session)
    @cards = CalibrationSessions::PersonCard.new(
      session: @session, stats: stats, capability_stable_id: params.expect(:id),
      visible_person_ids: visible_person_ids,
      # Shared so the session stream is read once per render, not once here
      # and again for the log.
      outcomes: outcomes
    )
    pinned_cards = resolve_pinned_cards(stats)
    # The log rides along as a side panel so an outcome raised here lands
    # in view without leaving the capability under discussion. Skipped for
    # a pane-frame request: those re-render the whole page server-side but
    # Turbo keeps only the frame, so the log would be built and discarded.
    #
    # NB this does NOT avoid the stream read — PersonCard needs the same
    # outcomes to mark an already-asked revisit — which is why the instance
    # above is shared rather than each building its own.
    session_log = session_log_data(@session, outcomes: outcomes) unless pane_frame_request?
    people_ids = (stats[:rater_ids] + log_person_ids(session_log)).compact.uniq

    person_card = @cards.for(params[:person].presence)
    focus_ordinal = person_focus_ordinal(person_card)
    render Views::CalibrationSessions::DrillInView.new(
      session: @session,
      stats: stats,
      people: Person.where(id: people_ids).index_by(&:id),
      session_log: session_log,
      can_note: @session.started? && policy(@session).flag_expectation?,
      person_card: person_card,
      person_focus_ordinal: focus_ordinal,
      person_action: params[:person_action].presence_in(PERSON_ACTIONS),
      request_candidates: evidence_request_candidates(person_card, focus_ordinal),
      view: view_param,
      wall: (evidence_wall(stats) if view_param == "wall"),
      wall_filters: wall_filters,
      pin_ids: pinned_cards.keys,
      pinned_cards: pinned_cards,
      can_flag: @session.started? && policy(@session).flag_expectation?,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  end

  private

  # Turbo asks for one frame by name; the side panel isn't in it.
  def pane_frame_request?
    request.headers["Turbo-Frame"] == "calibration-bottom-pane"
  end

  # @return [String, nil] "wall" / nil
  def view_param
    params[:view].presence_in(VIEWS)
  end

  # Pinned drawer cards, keyed by person_id. A pin only survives if it
  # RESOLVES to a card — an id outside the session, or one for someone who
  # has since left the cycle (so they hold no dot on this grid), is dropped
  # rather than becoming a phantom that shows no card, offers no "Unpin",
  # and permanently consumes one of the three slots. Resolve first, cap
  # last, so stale ids ahead of a live one can't squeeze it out.
  #
  # @return [Hash{String => Hash}]
  def resolve_pinned_cards(stats)
    # `compare[]` is the retired spelling — old bookmarks keep their pins.
    requested = Array.wrap(params[:pins].presence || params[:compare])
      .grep(String).select(&:present?).uniq
    (requested & grid_person_ids(stats))
      .filter_map { |person_id| @cards.for(person_id)&.then { |card| [ person_id, card ] } }
      .first(MAX_COMPARE_PINS).to_h
  end

  # The people the grid actually plots — the wall and the tray read the
  # same population, so every wall item has a dot to open.
  def grid_person_ids(stats)
    @grid_person_ids ||= stats[:levels].values.flatten.map { |dot| dot[:person_id] }
  end

  # Who the open person card can offer as evidence requestees — the
  # assessee's org neighbours, with pending asks on this cell greyed out
  # (the assessment surface's candidate rules verbatim). nil — no
  # affordance — when the viewer isn't entitled to this person's
  # assessment (AssesseeVisibility) or holds no linked Person: the same
  # bars the Operation enforces, checked up front so the card never
  # offers an ask that would be refused.
  # The strip's focused level: ?person_level= when it names a rung of the
  # card's ladder, else the assessed level — a person can be rated above
  # their level, and the room reads the whole column.
  def person_focus_ordinal(person_card)
    return nil unless person_card

    requested = params[:person_level].to_s.presence&.to_i
    ordinals = person_card[:levels].map { |level| level[:ordinal] }
    ordinals.include?(requested) ? requested : person_card[:ordinal]
  end

  def evidence_request_candidates(person_card, focus_ordinal)
    return nil unless person_card && current_person
    return nil unless @session.started?

    person_id = person_card[:dot][:person_id]
    return nil unless visible_person_ids.include?(person_id)

    assignment = PersonFrameworkAssignment.find_by(
      person_id: person_id, framework_id: @session.framework_id
    )
    return nil unless assignment

    Assessments::RequestCandidates.new(
      assignment: assignment,
      requester_person_id: current_person.id,
      capability_stable_id: params.expect(:id),
      # "Already asked" is per cell — grey out for the level on screen.
      level_ordinal: focus_ordinal
    ).suggestions
  end

  # Whose assessment the ACTING person may read. The session population can
  # legitimately include someone outside the facilitator's own subtree (see
  # ScopeChecks' delegation exemption), and that person's own feedback and
  # self-rating are not the facilitator's to read just because the session
  # lists them.
  #
  # Resolved from the session's population rather than the built grid, so it
  # is available to DrillInStats itself.
  def visible_person_ids
    @visible_person_ids ||= CalibrationSessions::AssesseeVisibility.new(
      viewer: current_person,
      framework_id: @session.framework_id,
      candidate_ids: CalibrationSessionMember.calibrants.where(session_id: @session.id).pluck(:person_id),
      admin: pundit_user.tenant_admin?
    ).person_ids
  end

  def evidence_wall(stats)
    CalibrationSessions::EvidenceWall.new(
      session: @session,
      capability_stable_id: params.expect(:id),
      person_ids: grid_person_ids(stats),
      visible_person_ids: visible_person_ids,
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
