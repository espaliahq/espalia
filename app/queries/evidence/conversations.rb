# frozen_string_literal: true

# The feedback a person has exchanged, grouped into conversations the way the
# Feedback / Evidence page lists them (#647): one per person, the most
# recently active first, each reading oldest to newest.
#
# What the viewer sees: requests they made or were sent, feedback they wrote,
# feedback about them, the answers to their requests, and feedback about
# anyone in their team or org (direct reports, rating delegations and the
# subtree below) from someone other than that person. A report's own notes
# appear only while they carry pending placement suggestions, as the old hub
# listed them.
#
# Which conversation a message belongs to, for the "person" group:
#
# 1. A request sits with the other party: whoever asked, or whoever was asked.
# 2. A reply stays with its request.
# 3. Feedback the viewer wrote sits with the person it is about; notes about
#    themselves sit with the viewer.
# 4. Any other feedback sits with its author.
#
# The "report" group keys every message about one of the viewer's reports by
# that report, and leaves the rest out.
class Evidence::Conversations
  GROUPS = %w[report person].freeze

  # One entry in a conversation. `kind` is :request (the ask), :reply (the
  # item answering it), :declined or :feedback (an item with no visible ask).
  Message = Data.define(:kind, :at, :request, :item) do
    # @return [String] the DOM id of the message's card, which old
    #   notification anchors (`#evidence-item-…`, `#evidence-request-…`) target
    def dom_id
      case kind
      when :request then request.dom_id
      when :declined then "#{request.dom_id}-declined"
      else EvidenceItem.dom_id(item.id)
      end
    end

    # The keys {Evidence::ConversationReads} matches unread notifications on.
    #
    # @return [Array<String>]
    def read_keys
      case kind
      when :request then [ "request:#{request.id}" ]
      when :declined then [ "declined:#{request.id}" ]
      when :reply then [ "item:#{item.id}", "replied:#{request.id}" ]
      else [ "item:#{item.id}" ]
      end
    end

    # @return [String] whose assessment the message is about
    def about_id = (request || item).person_id
  end

  Conversation = Data.define(:person_id, :messages, :owes, :waiting) do
    # @return [Time]
    def last_at = messages.last.at

    # @return [Message]
    def latest = messages.last
  end

  # The group a viewer sees first: their reports when they have any.
  #
  # @param viewer [Person]
  # @return [String]
  def self.default_group(viewer) = new(viewer).reports? ? "report" : "person"

  # @param viewer [Person]
  # @param group [String] "report" or "person"; anything else reads as "person"
  def initialize(viewer, group: "person")
    @viewer = viewer
    @group = group == "report" ? "report" : "person"
  end

  attr_reader :viewer, :group

  # @param group [String] the group the finders default to
  def group=(group)
    @group = group == "report" ? "report" : "person"
  end

  # @param group [String] defaults to the group this query was built for
  # @return [Array<Conversation>] the most recently active first
  def all(group: @group)
    group = group == "report" ? "report" : "person"
    (@all ||= {})[group] ||= begin
      buckets = messages.group_by { |message| key_for(message, group) }
      buckets.delete(nil)
      buckets.map { |person_id, list| conversation(person_id, list) }.sort_by { |c| [ -c.last_at.to_f, c.person_id ] }
    end
  end

  # @param person_id [String]
  # @param group [String]
  # @return [Conversation, nil]
  def find(person_id, group: @group) = all(group: group).find { |c| c.person_id == person_id }

  # The conversation holding a request or an item, so a link to one can land
  # on its thread.
  #
  # @param request_id [String, nil]
  # @param item_id [String, nil]
  # @param group [String]
  # @return [Conversation, nil]
  def containing(request_id: nil, item_id: nil, group: @group)
    all(group: group).find do |c|
      c.messages.any? { |m| (request_id && m.request&.id == request_id) || (item_id && m.item&.id == item_id) }
    end
  end

  # Whether the viewer has anyone in their team or org.
  #
  # @return [Boolean]
  def reports? = report_ids.any?

  # @param person_id [String]
  # @return [Boolean]
  def report?(person_id) = report_ids.include?(person_id)

  # Whether the message asks something of the viewer: a request to answer,
  # or feedback about them or their reports to place.
  #
  # @param message [Message]
  # @return [Boolean]
  def owes?(message)
    case message.kind
    when :request then message.request.pending? && message.request.requestee_person_id == viewer_id
    when :reply, :feedback then placeable?(message.item)
    else false
    end
  end

  # @return [Hash{String => Person}] the other party of each conversation, in
  #   either group
  def people
    @people ||= Person.where(id: (all(group: "person") + all(group: "report")).map(&:person_id).uniq).index_by(&:id)
  end

  private

  def viewer_id = @viewer.id

  def conversation(person_id, list)
    list = list.sort_by { |m| [ m.at, m.kind == :request ? 0 : 1 ] }
    Conversation.new(
      person_id: person_id, messages: list,
      owes: list.any? { |m| owes?(m) },
      waiting: list.any? { |m| m.kind == :request && m.request.pending? && m.request.requested_by_id == viewer_id }
    )
  end

  def key_for(message, group)
    return (report?(message.about_id) ? message.about_id : nil) if group == "report"
    return other_party(message.request) if message.request

    message.item.author_id == viewer_id ? message.item.person_id : message.item.author_id
  end

  def other_party(request)
    request.requested_by_id == viewer_id ? request.requestee_person_id : request.requested_by_id
  end

  def placeable?(item)
    return false if item.author_id == viewer_id || !unplaced_ids.include?(item.id)

    item.person_id == viewer_id || report?(item.person_id)
  end

  def messages
    @messages ||= begin
      by_id = items.index_by(&:id)
      answered = Set.new
      asked = requests.flat_map do |request|
        list = [ Message.new(kind: :request, at: request.requested_at, request: request, item: nil) ]
        reply = by_id[request.evidence_id] if request.status == "responded"
        if reply
          answered << reply.id
          list << Message.new(kind: :reply, at: reply.recorded_at, request: request, item: reply)
        elsif request.status == "declined"
          list << Message.new(kind: :declined, at: request.declined_at || request.updated_at, request: request, item: nil)
        end
        list
      end
      asked + items.reject { |item| answered.include?(item.id) }
        .map { |item| Message.new(kind: :feedback, at: item.recorded_at, request: nil, item: item) }
    end
  end

  def requests
    @requests ||= EvidenceRequest.outgoing_for(viewer_id).or(EvidenceRequest.incoming_for(viewer_id))
      .includes(:requester, :requestee, :assessee).to_a
  end

  def items
    @items ||= begin
      active = EvidenceItem.active
      own = active.where(author_id: viewer_id).or(active.where(person_id: viewer_id))
        .or(active.where(id: requests.filter_map(&:evidence_id)))
      (own.includes(:author).to_a + report_items).uniq(&:id)
    end
  end

  # Feedback about the viewer's reports from someone else. A report's own
  # notes only while they wait on a placement decision.
  def report_items
    return [] if report_keys.empty?

    about = EvidenceItem.active.where(person_id: report_ids.to_a).where.not(author_id: viewer_id)
    deciding = EvidencePlacementSuggestion.pending.where(person_id: report_ids.to_a).select(:evidence_id)
    about.where.not("evidence_items.author_id = evidence_items.person_id").or(about.where(id: deciding))
      .includes(:author).to_a.select { |item| report_keys.include?([ item.person_id, item.framework_id ]) }
  end

  def unplaced_ids
    @unplaced_ids ||= EvidenceItem.unplaced.where(id: items.map(&:id)).pluck(:id).to_set
  end

  def report_keys
    @report_keys ||= begin
      reviewable = Assessments::ReviewableAssignments.new(@viewer)
      (reviewable.team.to_a + reviewable.skip_level.to_a)
        .reject { |a| a.person_id == viewer_id }
        .to_set { |a| [ a.person_id, a.framework_id ] }
    end
  end

  def report_ids
    @report_ids ||= report_keys.to_set(&:first)
  end
end
