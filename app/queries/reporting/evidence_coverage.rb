# frozen_string_literal: true

# Aggregates feedback provision and evidence-request fulfilment for an
# assessment cycle across an authorised participant scope.
#
# Feedback is counted by EvidenceItem, never by EvidenceLink, so linking one
# item to several capabilities cannot inflate the report. Which cycle an item
# or request belongs to is {Reporting::EvidenceAttribution}'s decision, shared
# with the feedback export.
#
# An optional reporting period narrows the cycle's activity to one window:
# feedback recorded and requests sent inside it. Attribution runs first, so
# the period is always a slice of the cycle, never a way around it. Request
# statuses are their current state — a request sent in the window and
# answered later still reads as fulfilled.
#
# Each item is also counted once under the system it was given in
# (`external_reference.system`, nil meaning GrowthOS), so a figure combined
# with another system's counts every item where it was given. Imported items
# stay in `feedback_provided`; `by_origin` shows them apart.
#
# Privacy: this query returns workflow counts only. It never exposes evidence
# content, contributor identity, or individual request details.
class Reporting::EvidenceCoverage
  # Immutable provider-to-recipient feedback flow counts. Self feedback is
  # separate from the interpersonal denominator, while historical peer-source
  # evidence remains in an explicit combined bucket rather than being inferred
  # from today's org chart.
  Directionality = Data.define(
    :manager_to_report, :peer_to_peer, :report_to_manager,
    :self_provided, :legacy_peer_or_upward
  ) do
    # @return [Integer] active interpersonal feedback items
    def interpersonal_total
      manager_to_report + peer_to_peer + report_to_manager + legacy_peer_or_upward
    end

    # @param direction [Symbol] interpersonal direction attribute
    # @return [Integer] percentage of active interpersonal feedback
    def percentage_for(direction)
      return 0 if interpersonal_total.zero?

      (public_send(direction).to_f / interpersonal_total * 100).round
    end
  end

  # Aggregate counts for a cohort or group.
  Metrics = Data.define(
    :participant_count, :participants_with_feedback,
    :feedback_provided, :provided_by_request, :provided_unsolicited,
    :feedback_withdrawn, :directionality, :by_origin, :requests_sent, :requests_fulfilled,
    :requests_pending, :requests_declined, :requests_cancelled
  ) do
    # @return [Integer] percent of participants with active cycle feedback
    def participant_coverage_pct
      percentage(participants_with_feedback, participant_count)
    end

    # @return [Integer] percent of non-cancelled requests fulfilled
    def request_fulfillment_pct
      denominator = requests_sent - requests_cancelled
      percentage(requests_fulfilled, denominator)
    end

    private

    def percentage(numerator, denominator)
      denominator.zero? ? 0 : (numerator.to_f / denominator * 100).round
    end
  end

  # One manager, role, or level breakdown row.
  Group = Data.define(:key, :label, :metrics)

  ORIGIN_SYSTEM_SQL = "evidence_items.external_reference ->> 'system'"
  # Only the exchange importer writes `given_at`; it marks the system as a peer.
  ORIGIN_IMPORTED_SQL = "(evidence_items.external_reference -> 'metadata' ->> 'given_at') IS NOT NULL"
  private_constant :ORIGIN_SYSTEM_SQL, :ORIGIN_IMPORTED_SQL

  # Complete query result. `period` is the time window the counts were
  # narrowed to, or nil for the whole cycle.
  Result = Data.define(:cycle, :period, :metrics, :groups) do
    def any? = metrics.participant_count.positive?
  end

  Participant = Data.define(
    :person_id, :manager_id, :role_id, :role_name, :level_ordinal,
    :provided_ids, :requested_provided_ids, :withdrawn_ids,
    :feedback_directions, :provided_origins, :request_statuses
  )
  EvidenceRow = Data.define(
    :id, :person_id, :author_id, :link_status, :recorded_at, :cycle_id, :source, :feedback_direction,
    :origin_system, :origin_imported
  )
  private_constant :Participant, :EvidenceRow

  # @param cycle [AssessmentCycle]
  # @param scope_person_ids [Array<String>, nil] manager subtree, or nil for all
  # @param mode [Symbol] :summary omits grouped breakdowns; :full includes them
  # @param period [Range<Time>, nil] window to narrow feedback recorded and
  #   requests sent to; nil counts the whole cycle
  def initialize(cycle:, scope_person_ids: nil, mode: :full, period: nil)
    @cycle = cycle
    @scope_person_ids = scope_person_ids
    @mode = mode
    @period = period
  end

  # @return [Reporting::EvidenceCoverage::Result]
  def call
    enrollments = load_enrollments
    return empty_result if enrollments.empty?

    @participant_ids = enrollments.map(&:person_id)
    @attribution = Reporting::EvidenceAttribution.new(cycle: @cycle, person_ids: @participant_ids)
    request_rows = load_request_rows
    evidence_rows, requested_evidence_ids = load_evidence_rows
    participants = build_participants(
      enrollments, request_rows, evidence_rows, requested_evidence_ids
    )

    Result.new(
      cycle: @cycle,
      period: @period,
      metrics: build_metrics(participants),
      groups: @mode == :full ? build_groups(participants) : {}
    )
  end

  private

  def load_enrollments
    scope = AssessmentCycleEnrollment.active.where(cycle_id: @cycle.cycle_id)
    scope = scope.where(person_id: @scope_person_ids) if @scope_person_ids
    scope.to_a
  end

  def load_request_rows
    @attribution.attribute_requests(
      @attribution.request_refs(@attribution.request_scope(period: @period))
    )
  end

  def load_evidence_rows
    rows = @attribution.evidence_scope(period: @period)
      .pluck(:id, :person_id, :author_id, :link_status, :recorded_at, :cycle_id, :source, :feedback_direction,
             Arel.sql(ORIGIN_SYSTEM_SQL), Arel.sql(ORIGIN_IMPORTED_SQL))
      .map { |attributes| EvidenceRow.new(*attributes) }
    attributed = @attribution.attribute_evidence(rows)

    [ attributed.map(&:row), attributed.select(&:requested?).to_set { |entry| entry.row.id } ]
  end

  def reporting_direction(row)
    Reporting::EvidenceAttribution.reporting_direction(
      feedback_direction: row.feedback_direction, source: row.source,
      self_authored: row.author_id == row.person_id
    )
  end

  def build_participants(enrollments, request_rows, evidence_rows, requested_evidence_ids)
    requests_by_person = request_rows.group_by(&:person_id)
    evidence_by_person = evidence_rows.group_by(&:person_id)
    people = Person.where(id: @participant_ids).index_by(&:id)
    roles = FrameworkState::Role
      .where(role_id: enrollments.filter_map(&:role_id).uniq)
      .index_by(&:role_id)

    enrollments.map do |enrollment|
      items = evidence_by_person.fetch(enrollment.person_id, [])
      active = items.select { |item| item.link_status == "active" }
      person = people[enrollment.person_id]

      Participant.new(
        person_id: enrollment.person_id,
        manager_id: person&.manager_id,
        role_id: enrollment.role_id,
        role_name: roles[enrollment.role_id]&.name,
        level_ordinal: enrollment.level_ordinal,
        provided_ids: active.map(&:id).to_set,
        requested_provided_ids: active.filter_map do |item|
          item.id if requested_evidence_ids.include?(item.id)
        end.to_set,
        withdrawn_ids: items.filter_map { |item| item.id if item.link_status == "withdrawn" }.to_set,
        feedback_directions: active.map { |item| reporting_direction(item) },
        provided_origins: active.map { |item| Reporting::OriginLabels.key_for(item.origin_system, imported: item.origin_imported) }.tally,
        request_statuses: requests_by_person.fetch(enrollment.person_id, []).map(&:status)
      )
    end
  end

  def build_metrics(participants)
    statuses = participants.flat_map(&:request_statuses)
    provided = participants.sum { |participant| participant.provided_ids.size }
    requested = participants.sum { |participant| participant.requested_provided_ids.size }
    directions = participants.flat_map(&:feedback_directions).tally
    origins = participants.map(&:provided_origins).reduce({}) { |sum, tally| sum.merge(tally) { |_, a, b| a + b } }

    Metrics.new(
      participant_count: participants.size,
      participants_with_feedback: participants.count { |participant| participant.provided_ids.any? },
      feedback_provided: provided,
      provided_by_request: requested,
      provided_unsolicited: provided - requested,
      feedback_withdrawn: participants.sum { |participant| participant.withdrawn_ids.size },
      directionality: Directionality.new(
        manager_to_report: directions.fetch("manager_to_report", 0),
        peer_to_peer: directions.fetch("peer_to_peer", 0),
        report_to_manager: directions.fetch("report_to_manager", 0),
        self_provided: directions.fetch("self", 0),
        legacy_peer_or_upward: directions.fetch("legacy_peer_or_upward", 0)
      ),
      by_origin: origin_counts(origins),
      requests_sent: statuses.size,
      requests_fulfilled: statuses.count("responded"),
      requests_pending: statuses.count("pending"),
      requests_declined: statuses.count("declined"),
      requests_cancelled: statuses.count("cancelled")
    )
  end

  # GrowthOS first (always present, so a client can rely on the key), then
  # every other origin by count. The values sum to `feedback_provided`.
  def origin_counts(origins)
    native = Reporting::OriginLabels::NATIVE
    others = origins.except(native).sort_by { |origin, count| [ -count, origin ] }
    { native => origins.fetch(native, 0) }.merge(others.to_h)
  end

  def build_groups(participants)
    {
      manager: manager_groups(participants),
      role: grouped(participants, :role_id) { |participant| participant.role_name || "Unassigned role" },
      level: grouped(participants, :level_ordinal) do |participant|
        participant.level_ordinal ? "Level #{participant.level_ordinal}" : "No level"
      end
    }
  end

  def manager_groups(participants)
    manager_ids = participants.filter_map(&:manager_id).uniq
    names = Person.where(id: manager_ids).pluck(:id, :name).to_h
    grouped(participants, :manager_id) do |participant|
      participant.manager_id ? (names[participant.manager_id] || "Unknown manager") : "No manager"
    end
  end

  def grouped(participants, attribute)
    participants.group_by(&attribute).map do |key, members|
      Group.new(key: key, label: yield(members.first), metrics: build_metrics(members))
    end.sort_by { |group| [ -group.metrics.participant_count, group.label ] }
  end

  def empty_result
    Result.new(cycle: @cycle, period: @period, metrics: build_metrics([]), groups: {})
  end
end
