# frozen_string_literal: true

# Assembles one population member's drill-in card: their dot (at-level
# ratings + backing), the rater who owns the ratings, and — across EVERY
# level of their role's ladder for this capability — the ratings, the
# active feedback / evidence (relation-first authorship — the projected
# room sees "peer" / "manager" / "self", never a name by default), and the
# expectation text. A person can be rated above their level, so the card
# is a read-only adaptation of the assessment's capability view: the room
# reads the whole column, focused initially at the assessed level.
#
# Extracted from the drill-in controller so the inspector card and the
# pinned drawer cards (2–3 side by side) assemble through one code path.
class CalibrationSessions::PersonCard
  # @param session [CalibrationSession]
  # @param stats [Hash] DrillInStats result for the capability
  # @param capability_stable_id [String]
  # @param visible_person_ids [Array<String>, nil] population subset whose
  #   evidence the VIEWER may read ({CalibrationSessions::AssesseeVisibility}).
  #   nil means unfiltered — non-request callers only.
  # @param outcomes [CalibrationSessions::SessionOutcomes, nil] pass the
  #   request's existing instance so the session stream is read ONCE per
  #   render; omitted, this builds its own.
  def initialize(session:, stats:, capability_stable_id:, visible_person_ids: nil,
                 outcomes: nil)
    @session = session
    @stats = stats
    @capability_stable_id = capability_stable_id
    @visible_person_ids = visible_person_ids
    @outcomes = outcomes
    @cards = {}
  end

  # Memoized per person (misses included) so callers can ask freely — the
  # drawer resolves a pin and then renders it, and the opened person is
  # often also pinned. Each card costs a handful of queries.
  #
  # @param person_id [String, nil]
  # @return [Hash, nil] `{ dot:, ordinal:, rater_id:, evidence:, revisit_requested: }`
  #   — nil when the person isn't on this capability's grid
  def for(person_id)
    return nil if person_id.blank?
    return @cards[person_id] if @cards.key?(person_id)

    @cards[person_id] = build(person_id)
  end

  private

  def build(person_id)
    located = locate(person_id)
    return nil unless located

    dot, ordinal, rater_id = located
    evidence_by_level = evidence_for(person_id)
    {
      dot: dot,
      ordinal: ordinal,
      rater_id: rater_id,
      levels: ladder_for(person_id, ordinal),
      ratings_by_level: ratings_by_level(person_id, visible: visible?(person_id)),
      expectations_by_level: expectations_by_level,
      evidence_by_level: evidence_by_level,
      evidence: evidence_by_level[ordinal] || [],
      revisit_ordinals: revisit_ordinals(person_id),
      revisit_requested: revisit_ordinals(person_id).include?(ordinal),
      self_withheld: !visible?(person_id)
    }
  end

  # The level ladder the strip renders — the person's role ladder from the
  # ADR-19 enrollment snapshot. A pre-snapshot enrollment (no role_id)
  # degrades to just the assessed level, so the card still renders.
  #
  # @return [Array<Hash>] `[{ ordinal:, code: }]`, ascending
  def ladder_for(person_id, ordinal)
    role_id = AssessmentCycleEnrollment.active
      .find_by(cycle_id: @session.cycle_id, person_id: person_id)&.role_id
    levels = role_id ? FrameworkState::Level.where(role_id: role_id).order(:ordinal) : []
    return [ { ordinal: ordinal, code: "L#{ordinal}" } ] if levels.empty?

    levels.map { |level| { ordinal: level.ordinal, code: level.code.presence || "L#{level.ordinal}" } }
  end

  # Per-level rating frequencies for this capability, in the cells the
  # person's assessed role reads. Manager ratings are the session's business
  # and always shown; self ratings follow the same entitlement rule as
  # evidence (AssesseeVisibility) — withheld, not blanked, when the viewer
  # may not read this person's assessment.
  #
  # @return [Hash{Integer => Hash}] ordinal => { manager:, manager_carried:, self: }
  def ratings_by_level(person_id, visible:)
    AssessmentLevelRating.for_cycle(@session.cycle_id)
      .where(framework_id: @session.framework_id, capability_stable_id: @capability_stable_id)
      .within(Assessments::RoleScope.for_people(
        cycle_id: @session.cycle_id, framework_id: @session.framework_id, person_ids: [ person_id ]
      ))
      .to_h do |rating|
        [ rating.level_ordinal, {
          manager: rating.manager_rated_frequency,
          manager_carried: rating.manager_rated_frequency.present? &&
            rating.manager_rating_source == "seeded",
          self: visible ? rating.self_rated_frequency : nil
        } ]
      end
  end

  # Expectation text per level for this capability — shared across cards
  # (it's capability-scoped, not person-scoped). Scoped to the session's
  # framework: a cloned framework can carry the same stable_id, and the
  # wrong framework's text must never win the to_h.
  def expectations_by_level
    @expectations_by_level ||= FrameworkState::BehaviouralExpectation
      .joins(capability: :category)
      .where(framework_capabilities: { stable_id: @capability_stable_id })
      .merge(FrameworkState::CapabilityCategory.where(framework_id: @session.framework_id))
      .to_h { |expectation| [ expectation.level_ordinal, expectation.description ] }
  end

  def visible?(person_id)
    @visible_person_ids.nil? || @visible_person_ids.include?(person_id)
  end

  # @return [Array(Hash, Integer, String), nil] [dot, ordinal, rater_id]
  def locate(person_id)
    @stats[:levels].each do |ordinal, dots|
      dot = dots.find { |d| d[:person_id] == person_id }
      return [ dot, ordinal, dot[:rater_id] ] if dot
    end
    nil
  end

  # All levels at once — same query count as the old at-level read, the
  # card just stops throwing away the other levels' rows.
  #
  # @return [Hash{Integer => Array<Hash>}] ordinal => evidence entries
  def evidence_for(person_id)
    # The card still renders (ratings are the session's business); only the
    # free-text feedback is withheld when the viewer isn't entitled to it.
    return {} unless visible?(person_id)

    links = EvidenceLink.where(
      link_status: "active", framework_id: @session.framework_id,
      capability_stable_id: @capability_stable_id, person_id: person_id
    ).pluck(:evidence_id, :level_ordinal, :valence)

    # Resolved once per card, not per evidence item — it depends only on the
    # person, and a card can carry many items.
    manager_id = manager_id_for(person_id)
    items = EvidenceItem.active.where(id: links.map(&:first)).index_by(&:id)

    links.filter_map do |evidence_id, ordinal, valence|
      item = items[evidence_id]
      next unless item

      [ ordinal, {
        content: item.content,
        valence: valence,
        author_id: item.author_id,
        relation: author_relation(item.author_id, person_id, manager_id),
        recorded_at: item.recorded_at
      } ]
    end.group_by(&:first).transform_values do |entries|
      entries.map(&:last).sort_by { |entry| entry[:recorded_at] }.reverse
    end
  end

  # Relation-first authorship for the projected room — names stay off the
  # card by default (the facilitator can open the full assessment when
  # authorship genuinely matters). See the design doc's evidence rules.
  def author_relation(author_id, person_id, manager_id)
    return "self" if author_id == person_id

    author_id == manager_id ? "manager" : "peer"
  end

  def manager_id_for(person_id)
    RecordedReportingManager.manager_id_for(person_id, @session.framework_id) ||
      Person.find_by(id: person_id)&.manager_id
  end

  # The ordinals THIS session already asked the rater to revisit for this
  # capability — the card shows a marker at those levels instead of a
  # second ask (one ask per cell per session).
  def revisit_ordinals(person_id)
    @revisit_ordinals ||= {}
    @revisit_ordinals[person_id] ||= outcomes.revisit_requests
      .select { |r| r[:person_id] == person_id && r[:capability_stable_id] == @capability_stable_id }
      .to_set { |r| r[:level_ordinal] }
  end

  # Memoized across cards — the compare tray assembles up to three from one
  # instance, and the stream read shouldn't repeat per card. The controller
  # passes the one it already built for the log, so a full render reads the
  # stream once rather than twice.
  def outcomes
    @outcomes ||= CalibrationSessions::SessionOutcomes.new(session: @session)
  end
end
