# frozen_string_literal: true

# The drill-in's EVIDENCE WALL — all active feedback / evidence linked to
# one capability across the session's population, grouped by the linked
# cell's level, each item stamped with the manager-rated frequency its cell
# carries in the session's cycle (docs/architecture/calibration-sessions.md,
# "Evidence & feedback in the session" §d).
#
# Reading down a level, the room sees what behaviours each rating grade was
# actually awarded for across teams — the norming surface. The money shot is
# two near-identical pieces of evidence under divergent ratings.
#
# Anonymization is the VIEW's job (the wall follows the drill-in's reveal
# state client-side); this query returns full items and names — the
# facilitator is entitled to all of it, and the collapse is choreography,
# not privacy (the design doc's framing).
class CalibrationSessions::EvidenceWall
  # @param session [CalibrationSession]
  # @param capability_stable_id [String]
  # @param level [Integer, nil] filter to one level ordinal
  # @param valence [String, nil] filter to one EvidenceLink valence
  # @param rater_id [String, nil] filter to one participant's people
  def initialize(session:, capability_stable_id:, level: nil, valence: nil, rater_id: nil)
    @session = session
    @capability_stable_id = capability_stable_id
    @level = level
    @valence = valence
    @rater_id = rater_id
  end

  # @return [Hash] `{ groups:, rater_ids:, total: }` — groups are
  #   `[{ ordinal:, items: [...] }]`, highest level first; `rater_ids` lists
  #   every participant with at least one item (pre-filter), for the filter
  #   control; `total` counts items post-filter.
  def call
    filtered = items.select { |item| matches_filters?(item) }
    groups = filtered.group_by { |item| item[:level_ordinal] }
      .sort_by { |ordinal, _| -ordinal }
      .map { |ordinal, group| { ordinal: ordinal, items: group } }

    {
      groups: groups,
      rater_ids: items.map { |i| i[:rater_id] }.compact.uniq,
      total: filtered.size
    }
  end

  private

  def matches_filters?(item)
    return false if @level && item[:level_ordinal] != @level
    return false if @valence && item[:valence] != @valence
    return false if @rater_id && item[:rater_id] != @rater_id

    true
  end

  # One entry per (active link on this capability × population member),
  # any level — the wall shows every cell the item speaks to, not just the
  # at-level grid cells. Sorted newest-first within a level by the view's
  # grouping (items keep recorded_at order here).
  def items
    @items ||= begin
      links = EvidenceLink.where(
        link_status: "active",
        framework_id: @session.framework_id,
        capability_stable_id: @capability_stable_id,
        person_id: calibrant_ids
      ).pluck(:evidence_id, :person_id, :level_ordinal, :valence)

      item_rows = EvidenceItem.active.where(id: links.map(&:first).uniq)
        .pluck(:id, :content, :author_id, :recorded_at).to_h do |id, content, author_id, recorded_at|
          [ id, { content: content, author_id: author_id, recorded_at: recorded_at } ]
        end

      links.filter_map do |evidence_id, person_id, level_ordinal, valence|
        item = item_rows[evidence_id]
        next unless item

        {
          person_id: person_id,
          person_name: person_names[person_id],
          rater_id: rater_for[person_id],
          level_ordinal: level_ordinal,
          frequency: frequencies[[ person_id, level_ordinal ]],
          valence: valence,
          relation: relation_for(item[:author_id], person_id),
          content: item[:content],
          recorded_at: item[:recorded_at]
        }
      end.sort_by { |item| item[:recorded_at] }.reverse
    end
  end

  def calibrant_ids
    @calibrant_ids ||= @session.calibrants.pluck(:person_id)
  end

  # The manager-rated frequency each linked cell carries in the session's
  # cycle — the stamp beside every wall item.
  def frequencies
    @frequencies ||= AssessmentLevelRating
      .for_cycle(@session.cycle_id)
      .for_capability(@capability_stable_id)
      .where(person_id: calibrant_ids)
      .pluck(:person_id, :level_ordinal, :manager_rated_frequency)
      .to_h { |person_id, ordinal, frequency| [ [ person_id, ordinal ], frequency ] }
  end

  # The canonical attribution (who owns the person's ratings) for the rater
  # filter and the "«rater»'s report" line.
  def rater_for
    @rater_for ||= CalibrationSessions::PopulationSeeds.new(
      framework_id: @session.framework_id,
      participant_ids: @session.participants.pluck(:person_id),
      facilitator_id: @session.facilitator_id
    ).attribution
  end

  def relation_for(author_id, person_id)
    return "self" if author_id == person_id

    author_id == manager_ids[person_id] ? "manager" : "peer"
  end

  # Recorded reporting manager per population member (live fallback),
  # resolved in two batched queries rather than per item.
  def manager_ids
    @manager_ids ||= begin
      recorded = RecordedReportingManager
        .for_framework(@session.framework_id)
        .where(person_id: calibrant_ids)
        .pluck(:person_id, :manager_id).to_h
      live = Person.where(id: calibrant_ids - recorded.keys).pluck(:id, :manager_id).to_h
      recorded.merge(live)
    end
  end

  def person_names
    @person_names ||= Person.where(id: calibrant_ids).pluck(:id, :name).to_h
  end
end
