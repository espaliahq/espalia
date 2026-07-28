# frozen_string_literal: true

# Resolves the seed population for a calibration session: for each
# participant rater, the people whose ratings that participant owns on
# the session's framework — reports per the recorded reporting manager
# (live `Person.manager_id` fallback when nothing is recorded, mirroring
# AssessmentPolicy's authority rule) plus active manager-rating
# delegations. Limited to people actually assigned to the framework
# (someone with no assignment has no ratings to calibrate).
#
# Session raters (the participants and the facilitator) are excluded
# from every group — participants are calibrated in a separate session.
# The result is a SEED: the facilitator curates it in draft, and it is
# never silently re-derived (see docs/architecture/calibration-sessions.md,
# "Population rules") — the same query powers the explicit
# "refresh suggestions" affordance instead.
class CalibrationSessions::PopulationSeeds
  # @param framework_id [String] the cycle's framework
  # @param participant_ids [Array<String>] person_ids of the raters
  # @param facilitator_id [String, nil] excluded from every group alongside participants
  def initialize(framework_id:, participant_ids:, facilitator_id: nil)
    @framework_id = framework_id
    @participant_ids = participant_ids.uniq
    @facilitator_id = facilitator_id
  end

  # @return [Hash{String => Array<Person>}] participant_id => their seeded
  #   calibrants, name-ordered. Every participant key is present (possibly
  #   with an empty array). Derived from {#attribution}, so each person
  #   appears under exactly ONE participant.
  def call
    @call ||= begin
      grouped = attribution.keys.group_by { |person_id| attribution[person_id] }
      @participant_ids.index_with do |participant_id|
        people.values_at(*(grouped[participant_id] || [])).compact.sort_by(&:name)
      end
    end
  end

  # The CANONICAL person → participant attribution: each seeded person maps
  # to exactly one participant rater. When two participants both claim a
  # person (their recorded reporting manager AND an active rating delegate
  # sitting in the same room), the FIRST participant in participant_ids
  # order wins — an arbitrary but deterministic tiebreak. Every surface
  # (population groups, tendency strip, drill-in rows, revisit-request rater
  # resolution) must read THIS map so they can never disagree about who
  # owns a person's ratings.
  #
  # @return [Hash{String => String}] person_id => participant_id
  def attribution
    @attribution ||= {}.tap do |map|
      @participant_ids.each do |participant_id|
        (report_ids_for(participant_id) - excluded_ids).each do |person_id|
          map[person_id] ||= participant_id
        end
      end
    end
  end

  # The flat deduplicated seed list across all participants.
  #
  # @return [Array<String>] person_ids
  def person_ids
    attribution.keys
  end

  private

  def report_ids_for(participant_id)
    recorded = recorded_report_ids[participant_id] || []
    live = live_report_ids[participant_id] || []
    delegated = delegated_ids[participant_id] || []
    (recorded + live + delegated).uniq & assigned_person_ids
  end

  def excluded_ids
    @excluded_ids ||= @participant_ids + [ @facilitator_id ].compact
  end

  # person_ids with a recorded reporting manager among the participants,
  # grouped by that manager. Recorded rows are authoritative.
  def recorded_report_ids
    @recorded_report_ids ||= RecordedReportingManager
      .for_framework(@framework_id)
      .where(manager_id: @participant_ids)
      .pluck(:manager_id, :person_id)
      .group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last) }
  end

  # Live org-chart reports of the participants, EXCLUDING anyone who has
  # a recorded reporting manager for this framework (recorded overrides
  # live, even when it points elsewhere).
  def live_report_ids
    @live_report_ids ||= begin
      recorded_person_ids = RecordedReportingManager
        .for_framework(@framework_id)
        .pluck(:person_id)
      scope = Person.where(manager_id: @participant_ids)
      scope = scope.where.not(id: recorded_person_ids) if recorded_person_ids.any?
      scope.pluck(:manager_id, :id)
        .group_by(&:first)
        .transform_values { |pairs| pairs.map(&:last) }
    end
  end

  # Active manager-rating delegations held by the participants on this
  # framework — a seconded report a participant rates without managing.
  def delegated_ids
    @delegated_ids ||= ManagerAssessmentDelegation
      .active
      .for_framework(@framework_id)
      .where(delegate_person_id: @participant_ids)
      .pluck(:delegate_person_id, :person_id)
      .group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last) }
  end

  def assigned_person_ids
    @assigned_person_ids ||= PersonFrameworkAssignment
      .where(framework_id: @framework_id)
      .pluck(:person_id)
  end

  def people
    @people ||= begin
      all_ids = (recorded_report_ids.values + live_report_ids.values + delegated_ids.values)
        .flatten.uniq
      Person.where(id: all_ids).index_by(&:id)
    end
  end
end
