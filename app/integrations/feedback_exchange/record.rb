# frozen_string_literal: true

# Turns evidence items into protocol records (protocol §4).
#
# Built for a whole page at once: the people, answered requests, cycles and
# assessment links the records name are each read in one query, so a page costs
# the same however many items it holds. A record is emitted only when both
# people can be named by email; the others cannot be matched on the far side.
class FeedbackExchange::Record
  ORIGIN = "growthos"
  AUDIENCE = %w[recipient management_line hr].freeze
  NOTIFIED = %w[recipient manager].freeze

  # @param items [Array<EvidenceItem>] one page, in feed order
  # @return [Array<Hash>] the records for the items that can be named
  def self.for(items)
    new(items).records
  end

  # @param items [Array<EvidenceItem>]
  def initialize(items)
    @items = items
  end

  # @return [Array<Hash>]
  def records
    @items.filter_map { |item| record_for(item) }
  end

  private

  def record_for(item)
    author = people[item.author_id]
    recipient = people[item.person_id]
    return nil unless nameable?(author) && nameable?(recipient)

    {
      id: item.id,
      origin: ORIGIN,
      status: item.link_status,
      given_at: timestamp(item.recorded_at),
      updated_at: timestamp(item.updated_at),
      kind: item.evidence_type,
      text: text(item),
      text_format: "markdown",
      author: person(author),
      recipient: person(recipient),
      request: request_for(item),
      period: period_for(item),
      audience: AUDIENCE,
      notified: NOTIFIED,
      source_url: source_url(item),
      external_reference: external_reference(item)
    }
  end

  # Email is the only identity the protocol matches on (§3).
  def nameable?(person)
    person.present? && person.email.present?
  end

  # A withdrawn record carries no text: the author took the feedback back, and
  # the consumer needs only the status. Otherwise the title, which the protocol
  # has no field for, leads the text as a bold line.
  def text(item)
    return "" if item.withdrawn?

    item.title.present? ? "**#{item.title}**\n\n#{item.content}" : item.content
  end

  def timestamp(time)
    time.utc.iso8601(6)
  end

  def person(person)
    external_ids = person.hris_source.present? && person.external_id.present? ? { person.hris_source => person.external_id } : {}
    {
      email: person.email.to_s.downcase,
      display_name: person.name,
      active: person.status == "active",
      external_ids: external_ids
    }
  end

  def request_for(item)
    request = requests[item.id]
    return nil if request.nil?

    requester = people[request.requested_by_id]
    {
      id: request.id,
      context: request.message.presence,
      requested_by: requester && person(requester)
    }
  end

  def period_for(item)
    cycle = cycles[item.cycle_id]
    cycle && { id: cycle.cycle_id, name: cycle.name }
  end

  # Where the item can be read in GrowthOS: its cell in the assessment, or the
  # feedback hub while it is still unplaced. The recipient and their managers
  # can open the first; the second is the viewer's own list.
  def source_url(item)
    return nil if url_options[:host].blank?

    assignment_id = assignment_ids[[ item.person_id, item.framework_id ]]
    if assignment_id && item.capability_stable_id
      url_helpers.assessment_url(assignment_id, capability: item.capability_stable_id,
                                                level_ordinal: item.level_ordinal, **url_options)
    else
      url_helpers.evidence_hub_url(anchor: EvidenceItem.dom_id(item.id), **url_options)
    end
  end

  # The app's own address, as mail links use. Without a host there is no
  # absolute link to give, and `source_url` is null rather than a failed page.
  def url_options
    @url_options ||= Rails.application.config.action_mailer.default_url_options.to_h
  end

  def url_helpers
    Rails.application.routes.url_helpers
  end

  # Set only when this item itself came from another system through the exchange.
  def external_reference(item)
    reference = item.external_reference
    return nil unless item.recorded_via == FeedbackExchange::Feed::IMPORTED_VIA && reference&.system.present?

    { system: reference.system, id: reference.external_id }
  end

  def people
    @people ||= begin
      ids = @items.flat_map { |item| [ item.author_id, item.person_id ] } + requests.values.map(&:requested_by_id)
      Person.where(id: ids.uniq).index_by(&:id)
    end
  end

  # The answered request an item responds to, one per item.
  def requests
    @requests ||= EvidenceRequest.where(evidence_id: @items.map(&:id), status: "responded")
                                 .order(:responded_at).index_by(&:evidence_id)
  end

  def cycles
    @cycles ||= AssessmentCycle.where(cycle_id: @items.filter_map(&:cycle_id).uniq).index_by(&:cycle_id)
  end

  def assignment_ids
    @assignment_ids ||= PersonFrameworkAssignment
      .where(person_id: @items.map(&:person_id).uniq, framework_id: @items.map(&:framework_id).uniq)
      .pluck(:person_id, :framework_id, :id)
      .to_h { |person_id, framework_id, id| [ [ person_id, framework_id ], id ] }
  end
end
