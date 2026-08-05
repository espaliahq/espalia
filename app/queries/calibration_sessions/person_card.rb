# frozen_string_literal: true

# Assembles one population member's drill-in card: their dot (at-level
# ratings + backing), the rater who owns the ratings, the active feedback /
# evidence linked to this capability at their level (relation-first
# authorship — the projected room sees "peer" / "manager" / "self", never a
# name by default), and whether THIS session already asked for a revisit.
#
# Extracted from the drill-in controller so the person card and the compare
# tray (2–3 cards side by side) assemble through one code path.
class CalibrationSessions::PersonCard
  # @param session [CalibrationSession]
  # @param stats [Hash] DrillInStats result for the capability
  # @param capability_stable_id [String]
  # @param visible_person_ids [Array<String>, nil] population subset whose
  #   evidence the VIEWER may read ({CalibrationSessions::EvidenceVisibility}).
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
  # tray resolves a pin and then renders it, and the opened person is
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
    {
      dot: dot,
      ordinal: ordinal,
      rater_id: rater_id,
      evidence: evidence_for(person_id, ordinal),
      revisit_requested: revisit_requested?(person_id, ordinal)
    }
  end

  # @return [Array(Hash, Integer, String), nil] [dot, ordinal, rater_id]
  def locate(person_id)
    @stats[:rows].each do |row|
      row[:people].each do |ordinal, dots|
        dot = dots.find { |d| d[:person_id] == person_id }
        return [ dot, ordinal, row[:rater_id] ] if dot
      end
    end
    nil
  end

  def evidence_for(person_id, ordinal)
    # The card still renders (ratings are the session's business); only the
    # free-text feedback is withheld when the viewer isn't entitled to it.
    return [] if @visible_person_ids && !@visible_person_ids.include?(person_id)

    links = EvidenceLink.where(
      link_status: "active", framework_id: @session.framework_id,
      capability_stable_id: @capability_stable_id, person_id: person_id, level_ordinal: ordinal
    ).pluck(:evidence_id, :valence).to_h

    # Resolved once per card, not per evidence item — it depends only on the
    # person, and a card can carry many items.
    manager_id = manager_id_for(person_id)

    EvidenceItem.active.where(id: links.keys).order(recorded_at: :desc).map do |item|
      {
        content: item.content,
        valence: links[item.id],
        author_id: item.author_id,
        relation: author_relation(item.author_id, person_id, manager_id),
        recorded_at: item.recorded_at
      }
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

  # Whether THIS session already asked the rater to revisit this cell —
  # the card then shows the marker instead of a second ask.
  def revisit_requested?(person_id, ordinal)
    outcomes.revisit_requests.any? do |r|
      r[:person_id] == person_id &&
        r[:capability_stable_id] == @capability_stable_id &&
        r[:level_ordinal] == ordinal
    end
  end

  # Memoized across cards — the compare tray assembles up to three from one
  # instance, and the stream read shouldn't repeat per card. The controller
  # passes the one it already built for the log, so a full render reads the
  # stream once rather than twice.
  def outcomes
    @outcomes ||= CalibrationSessions::SessionOutcomes.new(session: @session)
  end
end
