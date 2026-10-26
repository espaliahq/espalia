# frozen_string_literal: true

# Decides which assessment cycle a piece of feedback, or an evidence request,
# belongs to. The cycle's feedback & evidence report counts by these rules and
# the feedback export lists by them, so the two can never disagree about which
# items a cycle holds.
#
# Attribution is immutable. An explicit `cycle_id` wins. A historical row
# without one is inferred only when its domain timestamp falls in exactly one
# of the person's enrollment windows in the cycle's framework. A historical
# response recorded after close inherits the cycle of the request it answered;
# evidence recorded before a request was reused, not provided in response, so
# it keeps its original provision cycle.
#
# Rows are duck-typed: evidence rows answer `id`, `person_id`, `recorded_at`
# and `cycle_id`; request rows answer `person_id`, `requested_at` and
# `cycle_id`. Plucked `Data` rows and loaded records both work.
#
# @example
#   attribution = Reporting::EvidenceAttribution.new(cycle: cycle, person_ids: ids)
#   attribution.attribute_evidence(attribution.evidence_scope.to_a)
class Reporting::EvidenceAttribution
  # One request, in the shape attribution reads.
  RequestRef = Data.define(
    :id, :person_id, :status, :evidence_id, :requested_at, :cycle_id, :requested_by_id
  )

  # A feedback row attributed to the cycle, with the cycle request it answered
  # (nil when it was given proactively, or answered a request it predates).
  Attributed = Data.define(:row, :request) do
    # @return [Boolean] whether the row counts as provided in response to a request
    def requested? = !request.nil?
  end

  Window = Data.define(:cycle_id, :starts_at, :ends_at)
  private_constant :Window

  REQUEST_COLUMNS = %i[id person_id status evidence_id requested_at cycle_id requested_by_id].freeze

  # The reporting direction of one feedback item: its immutable
  # `feedback_direction`, else the closest the legacy `source` can say.
  # Historical peer-source items cannot be split into peer and upward
  # feedback, so they land in their own combined bucket.
  #
  # An item the recipient wrote is self feedback whatever its event says
  # ({EvidenceItem#self_authored?}).
  #
  # @param feedback_direction [String, nil]
  # @param source [String]
  # @param self_authored [Boolean] whether the author is the recipient
  # @return [String] one of EvidenceItem::FEEDBACK_DIRECTIONS or "legacy_peer_or_upward"
  def self.reporting_direction(feedback_direction:, source:, self_authored:)
    return "self" if self_authored
    return feedback_direction if EvidenceItem::FEEDBACK_DIRECTIONS.include?(feedback_direction)

    case source
    when "manager" then "manager_to_report"
    when "self" then "self"
    else "legacy_peer_or_upward"
    end
  end

  # @param cycle [AssessmentCycle]
  # @param person_ids [Array<String>] the recipients whose feedback is attributed
  def initialize(cycle:, person_ids:)
    @cycle = cycle
    @person_ids = person_ids
  end

  # Feedback that could belong to the cycle — before attribution decides.
  #
  # @param period [Range<Time>, nil] narrows to items recorded inside it
  # @return [ActiveRecord::Relation<EvidenceItem>]
  def evidence_scope(period: nil)
    scope = EvidenceItem
      .where(person_id: @person_ids, framework_id: @cycle.framework_id)
      .where(cycle_id: [ nil, @cycle.cycle_id ])
    period ? scope.where(recorded_at: period) : scope
  end

  # Requests that could belong to the cycle — before attribution decides.
  #
  # @param period [Range<Time>, nil] narrows to requests sent inside it
  # @return [ActiveRecord::Relation<EvidenceRequest>]
  def request_scope(period: nil)
    scope = EvidenceRequest
      .where(person_id: @person_ids, framework_id: @cycle.framework_id)
      .where(cycle_id: [ nil, @cycle.cycle_id ])
    period ? scope.where(requested_at: period) : scope
  end

  # @param relation [ActiveRecord::Relation<EvidenceRequest>]
  # @return [Array<RequestRef>]
  def request_refs(relation)
    relation.pluck(*REQUEST_COLUMNS).map { |attributes| RequestRef.new(*attributes) }
  end

  # @param rows [Array] feedback rows from {#evidence_scope}
  # @return [Array<Attributed>] the rows attributed to this cycle
  def attribute_evidence(rows)
    refs_by_evidence = request_refs(EvidenceRequest.where(evidence_id: rows.map(&:id)))
      .group_by(&:evidence_id)

    rows.filter_map do |row|
      refs = refs_by_evidence.fetch(row.id, [])
      next unless evidence_cycle(row, refs) == @cycle.cycle_id

      qualifying = qualifying_response_refs(row, refs)
      answered = qualifying.min_by(&:requested_at) if resolved_request_cycle(qualifying) == @cycle.cycle_id
      Attributed.new(row: row, request: answered)
    end
  end

  # @param rows [Array] request rows from {#request_scope}
  # @return [Array] the rows attributed to this cycle
  def attribute_requests(rows)
    rows.select { |row| request_cycle(row) == @cycle.cycle_id }
  end

  private

  def evidence_cycle(row, request_refs)
    return row.cycle_id if row.cycle_id.present?

    qualifying = qualifying_response_refs(row, request_refs)
    return cycle_at(row.person_id, row.recorded_at) if qualifying.empty?

    resolved_request_cycle(qualifying)
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

    matches = windows_by_person.fetch(person_id, []).select do |window|
      timestamp >= window.starts_at && (window.ends_at.nil? || timestamp <= window.ends_at)
    end
    matches.one? ? matches.first.cycle_id : nil
  end

  # Every cycle window for the selected people in this framework, so a legacy
  # timestamp is accepted only when exactly one cycle contains it.
  def windows_by_person
    @windows_by_person ||= AssessmentCycleEnrollment
      .joins(:cycle)
      .where(person_id: @person_ids, assessment_cycles: { framework_id: @cycle.framework_id })
      .pluck(
        "assessment_cycle_enrollments.person_id",
        "assessment_cycle_enrollments.cycle_id",
        "assessment_cycle_enrollments.enrolled_at",
        "assessment_cycle_enrollments.withdrawn_at",
        "assessment_cycles.closed_at"
      )
      .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |row, windows|
        person_id, cycle_id, enrolled_at, withdrawn_at, closed_at = row
        windows[person_id] << Window.new(
          cycle_id: cycle_id,
          starts_at: enrolled_at,
          ends_at: [ withdrawn_at, closed_at ].compact.min
        )
      end
  end
end
