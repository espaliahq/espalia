# frozen_string_literal: true

# Assembles the capability drill-in for one calibration session: the
# expectation text per level beside a rater × level grid of the
# population's at-level manager ratings
# (docs/architecture/calibration-sessions.md, "Capability drill-in").
#
# Rows are raters; columns are assessed-level ordinals; each population
# member appears as one dot at (their rater, their level) carrying their
# manager-rated frequency (nil = unrated; a rater with NOTHING rated on
# this capability is collapsed by the view into a single "hasn't rated
# yet" sentence rather than a full row of grey dots) and
# whether the cell has active evidence backing. Population members whose
# rater is not a participant group into one muted "other raters" row
# (`rater_id: nil`) — reference points, visible but exempt from outcomes.
class CalibrationSessions::DrillInStats
  # @param session [CalibrationSession]
  # @param capability_stable_id [String]
  # @param visible_person_ids [Array<String>, nil] the population subset the
  #   viewer is entitled to an assessment for
  #   ({CalibrationSessions::AssesseeVisibility}). Outside it, the dot keeps
  #   its manager rating — the rater is in the room to defend it — but the
  #   assessee's own SELF rating is withheld. nil skips the gate entirely.
  def initialize(session:, capability_stable_id:, visible_person_ids: nil)
    @session = session
    @capability_stable_id = capability_stable_id
    @visible_person_ids = visible_person_ids&.to_set
  end

  # @return [Hash, nil] nil when the capability isn't in the session's
  #   framework; otherwise
  #   `{ capability:, ordinals:, expectations:, clarifications:, rows: }`
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
      illustrations: illustrations,
      clarifications: clarification_counts,
      flagged_illustration_ids: flagged_illustration_ids,
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

  # person_id => [assessed level ordinal, role_id] — the cycle enrollment
  # snapshot, both halves from the one row (see
  # #population_role_ids_by_ordinal for why the role comes from here).
  # Unenrolled members carry no assessed level and are omitted from the
  # grid — the setup page's readiness badges already surface them.
  def enrollment_snapshot
    @enrollment_snapshot ||= AssessmentCycleEnrollment.active
      .where(cycle_id: @session.cycle_id, person_id: calibrant_ids)
      .where.not(level_ordinal: nil)
      .pluck(:person_id, :level_ordinal, :role_id)
      .to_h { |person_id, ordinal, role_id| [ person_id, [ ordinal, role_id ] ] }
  end

  # person_id => assessed level ordinal.
  def assessed_ordinals
    @assessed_ordinals ||= enrollment_snapshot.transform_values(&:first)
  end

  def ordinals
    @ordinals ||= assessed_ordinals.values.uniq.sort
  end

  def expectations
    @expectations ||= FrameworkState::BehaviouralExpectation
      .where(capability_id: capability.capability_id, level_ordinal: ordinals)
      .pluck(:level_ordinal, :description).to_h
  end

  # Role illustrations per level, grouped by role — the clarifying examples
  # that sit under the canonical expectation. The room reads both together:
  # the expectation is what's rated, the illustrations are what it looks
  # like in a given role, and a disagreement often turns out to be two
  # raters reading different illustrations.
  #
  # Scoped to the roles ACTUALLY BEING CALIBRATED at each level — a
  # framework carries illustrations for every role, and examples for a role
  # nobody on this grid holds are noise the room has to read past.
  #
  # @return [Hash{Integer => Array<Hash>}] ordinal => [{ role_name:, items: }]
  def illustrations
    @illustrations ||= begin
      role_ids_by_ordinal = population_role_ids_by_ordinal
      return {} if role_ids_by_ordinal.empty?

      rows = FrameworkState::RoleIllustration
        .joins(:expectation, :role)
        .where(framework_behavioural_expectations: {
                 capability_id: capability.capability_id, level_ordinal: ordinals
               })
        .where(framework_roles: { role_id: role_ids_by_ordinal.values.reduce(:|).to_a })
        .order("framework_role_illustrations.ordinal", "framework_role_illustrations.created_at")
        .pluck("framework_behavioural_expectations.level_ordinal",
               "framework_roles.role_id",
               "framework_roles.name",
               "framework_role_illustrations.illustration_id",
               "framework_role_illustrations.description")

      rows
        .select { |ordinal, role_id, _, _, _| role_ids_by_ordinal[ordinal]&.include?(role_id) }
        .group_by(&:first)
        .transform_values do |group|
          group.group_by { |_, _, role_name, _, _| role_name }
            .map do |role_name, items|
              { role_name: role_name,
                items: items.map { |_, _, _, id, text| { id: id, text: text } } }
            end
            .sort_by { |group_hash| group_hash[:role_name].to_s }
        end
    end
  end

  # ordinal => Set of role_ids held by the population members assessed at
  # that level.
  #
  # Read from the CYCLE ENROLLMENT, not the live PersonFrameworkAssignment,
  # so role and level come from ONE row and cannot disagree. The enrollment
  # is the ADR-19 snapshot and carries `role_id` alongside `level_ordinal` —
  # the same pairing Assessments::MatrixDataBuilder gates on; the dot's
  # column has always come from it.
  #
  # The divergence is real once the cycle CLOSES. While it is open,
  # `ParticipantRoleSync` re-snapshots the enrollment on every HRIS
  # `PersonRoleChanged`, so both sources move together (the room's dot moves
  # levels too — that is the sync's intent, not something this query
  # second-guesses). After close the sync stops and the enrollment stays
  # frozen while the assignment keeps moving, so sourcing the role from the
  # assignment would show a closed session — the follow-through artifact,
  # read for months — the examples for a role the person moved into after
  # the ratings were made.
  #
  # Falls back to the live assignment only when the snapshot predates the
  # column.
  def population_role_ids_by_ordinal
    @population_role_ids_by_ordinal ||= begin
      snapshot = enrollment_role_ids
      missing = assessed_ordinals.keys - snapshot.compact.keys
      live = if missing.any?
        PersonFrameworkAssignment
          .where(framework_id: @session.framework_id, person_id: missing)
          .pluck(:person_id, :role_id).to_h
      else
        {}
      end

      assessed_ordinals.each_with_object({}) do |(person_id, ordinal), map|
        role_id = snapshot[person_id] || live[person_id]
        next unless role_id

        (map[ordinal] ||= Set.new) << role_id
      end
    end
  end

  # person_id => snapshot role_id, dropping the rows that predate the column.
  # A self-rating is the assessee's own input, so it needs the same
  # entitlement as their feedback. Reported separately from "unrated" —
  # rendering a withheld value as a gap would misread as data.
  def self_withheld?(person_id)
    return false if @visible_person_ids.nil?

    !@visible_person_ids.include?(person_id)
  end

  def enrollment_role_ids
    @enrollment_role_ids ||= enrollment_snapshot.transform_values(&:last).compact
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

  # Illustration ids under this capability with an OPEN clarification —
  # framework-wide like the cell counts, so overlapping sessions see each
  # other's example flags instead of re-flagging.
  #
  # @return [Set<String>]
  def flagged_illustration_ids
    @flagged_illustration_ids ||= FrameworkState::SuggestedEdit.pending.clarifications
      .where(framework_id: @session.framework_id, target_entity_type: "role_illustration")
      .where(target_entity_id: FrameworkState::RoleIllustration.joins(:expectation)
        .where(framework_behavioural_expectations: { capability_id: capability.capability_id })
        .select(:illustration_id))
      .pluck(:target_entity_id).to_set
  end

  # (person_id) => { frequency:, self_frequency:, carried: } for this
  # capability at the person's assessed level. `carried` = the manager value
  # was seeded from the previous cycle and not confirmed this one (ADR-20);
  # only "seeded" counts, nil being a legacy/factory row.
  def ratings
    @ratings ||= AssessmentLevelRating
      .for_cycle(@session.cycle_id)
      .for_capability(@capability_stable_id)
      .where(person_id: assessed_ordinals.keys, level_ordinal: ordinals)
      .pluck(:person_id, :level_ordinal, :manager_rated_frequency, :self_rated_frequency,
             :manager_rating_source)
      .each_with_object({}) do |(person_id, level_ordinal, manager_frequency, self_frequency, source), map|
        next unless level_ordinal == assessed_ordinals[person_id]

        map[person_id] = { frequency: manager_frequency, self_frequency: self_frequency,
                           carried: source == "seeded" }
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
              withheld = self_withheld?(person_id)
              {
                person_id: person_id,
                name: people[person_id]&.name || "Unknown",
                frequency: rating[:frequency],
                self_frequency: withheld ? nil : rating[:self_frequency],
                self_withheld: withheld,
                carried: rating[:carried] || false,
                backed: backed_person_ids.include?(person_id)
              }
            end.sort_by { |dot| dot[:name] }
          end
      }
    end
  end
end
