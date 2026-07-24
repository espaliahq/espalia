# frozen_string_literal: true

# Aggregates feedback provision and evidence-request fulfilment for an
# assessment cycle across an authorised participant scope.
#
# Feedback is counted by EvidenceItem, never by EvidenceLink, so linking one
# item to several capabilities cannot inflate the report. Cycle attribution is
# immutable: explicit cycle IDs win, while historical rows without one are
# inferred only when their domain timestamp falls in exactly one enrollment
# window. A historical response recorded after close inherits its request's
# inferred cycle; evidence recorded before a request remains attributed to its
# original provision cycle.
#
# Privacy: this query returns workflow counts only. It never exposes evidence
# content, contributor identity, or individual request details.
class Reporting::EvidenceCoverage
  # Aggregate counts for a cohort or group.
  Metrics = Data.define(
    :participant_count, :participants_with_feedback,
    :feedback_provided, :provided_by_request, :provided_unsolicited,
    :feedback_withdrawn, :requests_sent, :requests_fulfilled,
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

  # Complete query result.
  Result = Data.define(:cycle, :metrics, :groups) do
    def any? = metrics.participant_count.positive?
  end

  Participant = Data.define(
    :person_id, :manager_id, :role_id, :role_name, :level_ordinal,
    :provided_ids, :requested_provided_ids, :withdrawn_ids, :request_statuses
  )
  RequestRow = Data.define(:id, :person_id, :status, :evidence_id, :requested_at, :cycle_id)
  EvidenceRow = Data.define(:id, :person_id, :link_status, :recorded_at, :cycle_id)
  Window = Data.define(:cycle_id, :starts_at, :ends_at)
  private_constant :Participant, :RequestRow, :EvidenceRow, :Window

  # @param cycle [AssessmentCycle]
  # @param scope_person_ids [Array<String>, nil] manager subtree, or nil for all
  # @param mode [Symbol] :summary omits grouped breakdowns; :full includes them
  def initialize(cycle:, scope_person_ids: nil, mode: :full)
    @cycle = cycle
    @scope_person_ids = scope_person_ids
    @mode = mode
  end

  # @return [Reporting::EvidenceCoverage::Result]
  def call
    enrollments = load_enrollments
    return empty_result if enrollments.empty?

    @participant_ids = enrollments.map(&:person_id)
    @windows_by_person = load_windows
    request_rows = load_request_rows
    evidence_rows, requested_evidence_ids = load_evidence_rows
    participants = build_participants(
      enrollments, request_rows, evidence_rows, requested_evidence_ids
    )

    Result.new(
      cycle: @cycle,
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

  # Load every cycle window for the selected people in this framework so a
  # legacy timestamp is accepted only when exactly one cycle contains it.
  def load_windows
    rows = AssessmentCycleEnrollment
      .joins(:cycle)
      .where(person_id: @participant_ids, assessment_cycles: { framework_id: @cycle.framework_id })
      .pluck(
        "assessment_cycle_enrollments.person_id",
        "assessment_cycle_enrollments.cycle_id",
        "assessment_cycle_enrollments.enrolled_at",
        "assessment_cycle_enrollments.withdrawn_at",
        "assessment_cycles.closed_at"
      )

    rows.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |row, windows|
      person_id, cycle_id, enrolled_at, withdrawn_at, closed_at = row
      windows[person_id] << Window.new(
        cycle_id: cycle_id,
        starts_at: enrolled_at,
        ends_at: [ withdrawn_at, closed_at ].compact.min
      )
    end
  end

  def load_request_rows
    EvidenceRequest
      .where(person_id: @participant_ids, framework_id: @cycle.framework_id)
      .where(cycle_id: [ nil, @cycle.cycle_id ])
      .pluck(:id, :person_id, :status, :evidence_id, :requested_at, :cycle_id)
      .map { |attributes| RequestRow.new(*attributes) }
      .select { |row| request_cycle(row) == @cycle.cycle_id }
  end

  def load_evidence_rows
    rows = EvidenceItem
      .where(person_id: @participant_ids, framework_id: @cycle.framework_id)
      .where(cycle_id: [ nil, @cycle.cycle_id ])
      .pluck(:id, :person_id, :link_status, :recorded_at, :cycle_id)
      .map { |attributes| EvidenceRow.new(*attributes) }

    refs_by_evidence = response_references(rows.map(&:id))
    attributed = rows.select do |row|
      evidence_cycle(row, refs_by_evidence.fetch(row.id, [])) == @cycle.cycle_id
    end
    requested_ids = attributed.filter_map do |row|
      row.id if response_cycle(row, refs_by_evidence.fetch(row.id, [])) == @cycle.cycle_id
    end.to_set

    [ attributed, requested_ids ]
  end

  def response_references(evidence_ids)
    return {} if evidence_ids.empty?

    EvidenceRequest
      .where(evidence_id: evidence_ids)
      .pluck(:id, :person_id, :status, :evidence_id, :requested_at, :cycle_id)
      .map { |attributes| RequestRow.new(*attributes) }
      .group_by(&:evidence_id)
  end

  def evidence_cycle(row, request_refs)
    return row.cycle_id if row.cycle_id.present?

    qualifying_refs = qualifying_response_refs(row, request_refs)
    return cycle_at(row.person_id, row.recorded_at) if qualifying_refs.empty?

    resolved_request_cycle(qualifying_refs)
  end

  def response_cycle(row, request_refs)
    qualifying_refs = qualifying_response_refs(row, request_refs)
    return nil if qualifying_refs.empty?

    resolved_request_cycle(qualifying_refs)
  end

  # Evidence predating the request was reused, not provided in response.
  def qualifying_response_refs(row, request_refs)
    request_refs.select do |request|
      request.requested_at.present? && request.requested_at <= row.recorded_at
    end
  end

  def resolved_request_cycle(request_rows)
    cycles = request_rows.map { |request| request_cycle(request) }
    return nil if cycles.any?(&:nil?) || cycles.uniq.size != 1

    cycles.first
  end

  def request_cycle(row)
    row.cycle_id.presence || cycle_at(row.person_id, row.requested_at)
  end

  def cycle_at(person_id, timestamp)
    return nil if timestamp.nil?

    matches = @windows_by_person.fetch(person_id, []).select do |window|
      timestamp >= window.starts_at && (window.ends_at.nil? || timestamp <= window.ends_at)
    end
    matches.one? ? matches.first.cycle_id : nil
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
        request_statuses: requests_by_person.fetch(enrollment.person_id, []).map(&:status)
      )
    end
  end

  def build_metrics(participants)
    statuses = participants.flat_map(&:request_statuses)
    provided = participants.sum { |participant| participant.provided_ids.size }
    requested = participants.sum { |participant| participant.requested_provided_ids.size }

    Metrics.new(
      participant_count: participants.size,
      participants_with_feedback: participants.count { |participant| participant.provided_ids.any? },
      feedback_provided: provided,
      provided_by_request: requested,
      provided_unsolicited: provided - requested,
      feedback_withdrawn: participants.sum { |participant| participant.withdrawn_ids.size },
      requests_sent: statuses.size,
      requests_fulfilled: statuses.count("responded"),
      requests_pending: statuses.count("pending"),
      requests_declined: statuses.count("declined"),
      requests_cancelled: statuses.count("cancelled")
    )
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
    Result.new(cycle: @cycle, metrics: build_metrics([]), groups: {})
  end
end
