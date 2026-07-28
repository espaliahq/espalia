# frozen_string_literal: true

# Assembles the capability drill-in for one calibration session: the
# expectation text per level beside a rater × level grid of the
# population's at-level manager ratings
# (docs/architecture/calibration-sessions.md, "Capability drill-in").
#
# Rows are raters; columns are assessed-level ordinals; each population
# member appears as one dot at (their rater, their level) carrying their
# manager-rated frequency (nil = unrated — the gap is data too) and
# whether the cell has active evidence backing. Population members whose
# rater is not a participant group into one muted "other raters" row
# (`rater_id: nil`) — reference points, visible but exempt from outcomes.
class CalibrationSessions::DrillInStats
  # @param session [CalibrationSession]
  # @param capability_stable_id [String]
  def initialize(session:, capability_stable_id:)
    @session = session
    @capability_stable_id = capability_stable_id
  end

  # @return [Hash, nil] nil when the capability isn't in the session's
  #   framework; otherwise `{ capability:, ordinals:, expectations:, rows: }`
  def call
    return nil unless capability

    {
      capability: {
        stable_id: @capability_stable_id,
        name: capability.name,
        category_name: capability.category&.name
      },
      ordinals: ordinals,
      expectations: expectations,
      clarifications: clarification_counts,
      rows: rows
    }
  end

  private

  def capability
    @capability ||= FrameworkState::Capability
      .joins(:category)
      .where(framework_capability_categories: { framework_id: @session.framework_id })
      .find_by(stable_id: @capability_stable_id)
  end

  def participant_ids
    @participant_ids ||= @session.participants.pluck(:person_id)
  end

  def calibrant_ids
    @calibrant_ids ||= @session.calibrants.pluck(:person_id)
  end

  # population person_id => participant person_id (nil when their rater
  # isn't in the session). Reads the canonical PopulationSeeds#attribution
  # so the grid rows, the tendency strip, and the revisit-request rater
  # resolution always name the same rater for a person.
  def rater_for
    @rater_for ||= begin
      attributed = CalibrationSessions::PopulationSeeds.new(
        framework_id: @session.framework_id,
        participant_ids: participant_ids,
        facilitator_id: @session.facilitator_id
      ).attribution
      calibrant_ids.index_with { |person_id| attributed[person_id] }
    end
  end

  # person_id => assessed level ordinal (cycle enrollment snapshot).
  # Unenrolled members carry no assessed level and are omitted from the
  # grid — the setup page's readiness badges already surface them.
  def assessed_ordinals
    @assessed_ordinals ||= AssessmentCycleEnrollment.active
      .where(cycle_id: @session.cycle_id, person_id: calibrant_ids)
      .where.not(level_ordinal: nil)
      .pluck(:person_id, :level_ordinal).to_h
  end

  def ordinals
    @ordinals ||= assessed_ordinals.values.uniq.sort
  end

  def expectations
    @expectations ||= FrameworkState::BehaviouralExpectation
      .where(capability_id: capability.capability_id, level_ordinal: ordinals)
      .pluck(:level_ordinal, :description).to_h
  end

  # ordinal => count of OPEN framework clarifications anchored on this
  # capability's cells — deliberately framework-wide, not session-scoped, so
  # a later session sees "already flagged by Engineering" instead of blindly
  # re-flagging (overlapping sessions roll up, never re-litigate).
  #
  # @return [Hash{Integer => Integer}]
  def clarification_counts
    @clarification_counts ||= begin
      counts = Hash.new(0)
      exp_levels = FrameworkState::BehaviouralExpectation
        .where(capability_id: capability.capability_id)
        .pluck(:expectation_id, :level_ordinal).to_h
      scope = FrameworkState::SuggestedEdit.pending.clarifications
        .where(framework_id: @session.framework_id)

      scope.where(target_entity_type: "behavioural_expectation", target_entity_id: exp_levels.keys)
        .pluck(:target_entity_id).each { |eid| counts[exp_levels[eid]] += 1 }
      scope.where(target_entity_type: "capability", target_entity_id: capability.capability_id)
        .pluck(:proposed_attributes).each do |attrs|
          ordinal = attrs&.dig("level_ordinal")
          counts[ordinal.to_i] += 1 if ordinal
        end
      counts
    end
  end

  # (person_id) => { frequency:, self_frequency: } for this capability at
  # the person's assessed level.
  def ratings
    @ratings ||= AssessmentLevelRating
      .for_cycle(@session.cycle_id)
      .for_capability(@capability_stable_id)
      .where(person_id: assessed_ordinals.keys, level_ordinal: ordinals)
      .pluck(:person_id, :level_ordinal, :manager_rated_frequency, :self_rated_frequency)
      .each_with_object({}) do |(person_id, level_ordinal, manager_frequency, self_frequency), map|
        next unless level_ordinal == assessed_ordinals[person_id]

        map[person_id] = { frequency: manager_frequency, self_frequency: self_frequency }
      end
  end

  def backed_person_ids
    @backed_person_ids ||= begin
      links = EvidenceLink
        .where(link_status: "active", framework_id: @session.framework_id,
               capability_stable_id: @capability_stable_id, person_id: assessed_ordinals.keys)
        .pluck(:evidence_id, :person_id, :level_ordinal)
      active_ids = EvidenceItem.active.where(id: links.map(&:first).uniq).pluck(:id).to_set
      links.filter_map do |evidence_id, person_id, ordinal|
        person_id if active_ids.include?(evidence_id) && ordinal == assessed_ordinals[person_id]
      end.to_set
    end
  end

  # One row per participant (in session order), plus a trailing
  # `rater_id: nil` row when unattributed members exist.
  def rows
    people = Person.where(id: assessed_ordinals.keys).index_by(&:id)
    grouped = assessed_ordinals.keys.group_by { |person_id| rater_for[person_id] }

    ordered_raters = participant_ids + (grouped.key?(nil) ? [ nil ] : [])
    ordered_raters.map do |rater_id|
      members = grouped.fetch(rater_id, [])
      {
        rater_id: rater_id,
        in_session: !rater_id.nil?,
        people: members.group_by { |person_id| assessed_ordinals[person_id] }
          .transform_values do |ids|
            ids.map do |person_id|
              rating = ratings[person_id] || {}
              {
                person_id: person_id,
                name: people[person_id]&.name || "Unknown",
                frequency: rating[:frequency],
                self_frequency: rating[:self_frequency],
                backed: backed_person_ids.include?(person_id)
              }
            end.sort_by { |dot| dot[:name] }
          end
      }
    end
  end
end
