# frozen_string_literal: true

# One row per piece of feedback (EvidenceItem) a cycle holds, for the tenant
# admin's monthly reporting export. The cycle's items are exactly the ones
# its feedback & evidence report counts: the same participants (active
# enrollments) and the same {Reporting::EvidenceAttribution} rules, so with
# withdrawn items left out the row count equals the report's
# `feedback_provided`.
#
# Unlike that report this carries names and content, which is why only the
# tenant-admin export reads it. Every value is a plain String (or nil) so the
# rows serialise to JSON for MCP and to CSV for the web without translation.
class Reporting::FeedbackExport
  DIRECTION_LABELS = {
    "manager_to_report" => "Manager → report",
    "peer_to_peer" => "Peer → peer",
    "report_to_manager" => "Report → manager",
    "self" => "Self",
    "legacy_peer_or_upward" => "Peer → peer or report → manager (historical)"
  }.freeze

  # @param cycle [AssessmentCycle]
  # @param period [Range<Time>, nil] narrows to feedback recorded inside it
  # @param include_withdrawn [Boolean] whether withdrawn feedback is listed
  def initialize(cycle:, period: nil, include_withdrawn: false)
    @cycle = cycle
    @period = period
    @include_withdrawn = include_withdrawn
  end

  # @return [Array<Hash{Symbol=>String, nil}>] oldest feedback first
  def call
    @enrollments = AssessmentCycleEnrollment.active.where(cycle_id: @cycle.cycle_id).index_by(&:person_id)
    return [] if @enrollments.empty?

    attribution = Reporting::EvidenceAttribution.new(cycle: @cycle, person_ids: @enrollments.keys)
    scope = attribution.evidence_scope(period: @period)
    scope = scope.active unless @include_withdrawn
    attributed = attribution.attribute_evidence(scope.order(:recorded_at, :id).to_a)
    load_lookups(attributed)

    attributed.map { |entry| row(entry.row, entry.request) }
  end

  private

  def row(item, request)
    recipient = @people[item.person_id]
    provider = @people[item.author_id]
    recipient_role, recipient_level = role_and_level(item.person_id)
    provider_role, = role_and_level(item.author_id)

    {
      cycle: @cycle.name,
      recorded_at: timestamp(item.recorded_at),
      recipient: recipient&.name,
      recipient_email: recipient&.email,
      recipient_role: recipient_role&.name,
      recipient_level: recipient_level&.title,
      recipient_manager: @people[recipient&.manager_id]&.name,
      provider: provider&.name,
      provider_email: provider&.email,
      provider_role: provider_role&.name,
      direction: DIRECTION_LABELS.fetch(
        Reporting::EvidenceAttribution.reporting_direction(
          feedback_direction: item.feedback_direction, source: item.source,
          self_authored: item.self_authored?
        )
      ),
      requested: request ? "Requested" : "Proactive",
      requested_by: request && @people[request.requested_by_id]&.name,
      requested_at: request && timestamp(request.requested_at),
      type: type_label(item),
      title: item.title,
      feedback: item.content,
      applies_to: applies_to(item, recipient_role),
      status: item.link_status.humanize,
      withdrawn_at: timestamp(item.withdrawn_at),
      reference_link: item.external_reference&.safe_url,
      origin: Reporting::OriginLabels.label(item.external_reference&.system,
                                            imported: item.external_reference&.imported? || false),
      origin_request: origin_request(item)
    }
  end

  # What the item's source system said it answered there. "Requested or
  # proactive" is only ever about an Espalia request, so this is how a reader
  # sees that a peer's item was asked for.
  def origin_request(item)
    metadata = item.external_reference&.metadata
    context = metadata.is_a?(Hash) ? metadata.with_indifferent_access[:request_context] : nil
    context.is_a?(String) ? context.presence : nil
  end

  def load_lookups(attributed)
    items = attributed.map(&:row)
    @links = shown_links(items)
    placed_ids = items.flat_map { |item| [ item.person_id, item.author_id ] }.uniq
    load_people(placed_ids, items, attributed.filter_map(&:request))
    load_roles_and_levels(placed_ids)
    @capability_names = capability_names(@links.values.flatten.map(&:capability_stable_id).uniq)
  end

  # The links an item applies to now. A withdrawn item a framework migration
  # orphaned has none left, so it shows the ones it had rather than nothing.
  def shown_links(items)
    EvidenceLink.where(evidence_id: items.map(&:id)).order(:linked_at, :id).group_by(&:evidence_id)
      .transform_values { |links| links.select { |link| link.link_status == "active" }.presence || links }
  end

  def load_people(placed_ids, items, requests)
    @people = Person.where(id: placed_ids + requests.map(&:requested_by_id)).index_by(&:id)
    recipients = items.map(&:person_id).uniq.filter_map { |id| @people[id] }
    managers = Person.where(id: recipients.filter_map(&:manager_id) - @people.keys)
    managers.each { |manager| @people[manager.id] = manager }
  end

  # A person's role and level as this cycle saw them: their enrollment
  # snapshot when they took part, else their live framework assignment.
  def load_roles_and_levels(people_ids)
    provider_enrollments = AssessmentCycleEnrollment
      .where(cycle_id: @cycle.cycle_id, person_id: people_ids - @enrollments.keys)
      .index_by(&:person_id)
    assignments = PersonFrameworkAssignment
      .where(framework_id: @cycle.framework_id, person_id: people_ids)
      .index_by(&:person_id)

    @placements = people_ids.index_with do |person_id|
      source = @enrollments[person_id] || provider_enrollments[person_id]
      source = assignments[person_id] unless source&.role_id
      source && [ source.role_id, source.level_id ]
    end

    placed = @placements.values.compact
    @roles = FrameworkState::Role.where(role_id: placed.map(&:first).uniq).index_by(&:role_id)
    levels = FrameworkState::Level.where(role_id: @roles.keys).to_a
    @levels_by_id = levels.index_by(&:level_id)
    @level_codes = levels.to_h { |level| [ [ level.role_id, level.ordinal ], level.code ] }
  end

  def role_and_level(person_id)
    role_id, level_id = @placements[person_id]
    [ @roles[role_id], @levels_by_id[level_id] ]
  end

  # Names come from the cycle's own framework: a stable id is not unique
  # across frameworks, and an active row wins over an archived one.
  def capability_names(stable_ids)
    FrameworkState::Capability
      .joins(:category)
      .where(stable_id: stable_ids, framework_capability_categories: { framework_id: @cycle.framework_id })
      .order(Arel.sql("CASE framework_capabilities.status WHEN 'active' THEN 0 ELSE 1 END"))
      .pluck(:stable_id, :name)
      .each_with_object({}) { |(stable_id, name), names| names[stable_id] ||= name }
  end

  def applies_to(item, role)
    @links.fetch(item.id, []).map do |link|
      [
        @capability_names.fetch(link.capability_stable_id, "Unknown capability"),
        level_code(role, link.level_ordinal),
        Views::Evidence::Valence::LABELS[link.valence]
      ].compact.join(" · ")
    end.join("; ")
  end

  def level_code(role, ordinal)
    @level_codes[[ role&.role_id, ordinal ]] || "L#{ordinal}"
  end

  def type_label(item)
    return item.custom_type_label.presence || "Other" if item.evidence_type == "other"

    item.evidence_type.humanize
  end

  def timestamp(time)
    time&.utc&.iso8601
  end
end
