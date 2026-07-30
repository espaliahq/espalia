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
# Returns full items and names: the room discusses what was actually
# written about whom (docs/architecture/calibration-sessions.md, "Naming").
class CalibrationSessions::EvidenceWall
  # @param session [CalibrationSession]
  # @param capability_stable_id [String]
  # @param person_ids [Array<String>, nil] the population to read; defaults
  #   to the session's calibrants. The drill-in passes the grid's population
  #   so the wall and the grid agree on who is on screen — every wall item
  #   needs a dot to open.
  # @param level [Integer, nil] filter to one level ordinal
  # @param valence [String, nil] filter to one EvidenceLink valence
  # @param rater_id [String, nil] filter to one participant's people
  def initialize(session:, capability_stable_id:, person_ids: nil, level: nil,
                 valence: nil, rater_id: nil)
    @session = session
    @capability_stable_id = capability_stable_id
    @person_ids = person_ids
    @level = level
    @valence = valence
    @rater_id = rater_id
  end

  # @return [Hash] `{ groups:, level_ordinals:, rater_ids:, total: }` —
  #   groups are `[{ ordinal:, items: [...] }]`, highest level first;
  #   `level_ordinals` and `rater_ids` describe what the wall actually holds
  #   (pre-filter), for the filter controls; `total` counts items
  #   post-filter.
  def call
    filtered = items.select { |item| matches_filters?(item) }
    groups = filtered.group_by { |item| item[:level_ordinal] }
      .sort_by { |ordinal, _| -ordinal }
      .map { |ordinal, group| { ordinal: ordinal, items: group } }

    {
      groups: groups,
      # Levels come from the items, not the grid: evidence can be linked to a
      # level nobody in the population is assessed at, and a group the wall
      # renders must be selectable.
      level_ordinals: items.map { |i| i[:level_ordinal] }.uniq.sort.reverse,
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
          frequency: frequencies.dig([ person_id, level_ordinal ], :frequency),
          # Marks a stamp whose rating was carried from the previous cycle
          # and not confirmed this one — the room shouldn't norm against a
          # grade nobody awarded this time round.
          frequency_carried: frequencies.dig([ person_id, level_ordinal ], :carried) || false,
          valence: valence,
          relation: relation_for(item[:author_id], person_id),
          content: item[:content],
          recorded_at: item[:recorded_at]
        }
      end.sort_by { |item| item[:recorded_at] }.reverse
    end
  end

  def calibrant_ids
    @calibrant_ids ||= @person_ids || @session.calibrants.pluck(:person_id)
  end

  # The manager-rated frequency each linked cell carries in the session's
  # cycle — the stamp beside every wall item.
  def frequencies
    @frequencies ||= AssessmentLevelRating
      .for_cycle(@session.cycle_id)
      .for_capability(@capability_stable_id)
      .where(person_id: calibrant_ids)
      .pluck(:person_id, :level_ordinal, :manager_rated_frequency, :manager_rating_source)
      .to_h do |person_id, ordinal, frequency, source|
        [ [ person_id, ordinal ], { frequency: frequency, carried: source == "seeded" } ]
      end
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
