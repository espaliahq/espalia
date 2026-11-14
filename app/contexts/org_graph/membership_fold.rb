# frozen_string_literal: true

# A person's current memberships, folded from their membership events. The
# person aggregate and the Members projection both read memberships this way,
# so what a command checks against, the live member list and History agree.
#
# A set dated earlier than the terms held moves the start back and keeps the
# later terms. A change-back dated on the day of the change it reverses
# withdraws that change, as History does: both drop out and the rest is
# folded again.
#
class OrgGraph::MembershipFold
  EVENTS = [ OrgGraph::Events::MembershipSet, OrgGraph::Events::MembershipEnded, OrgGraph::Events::MembershipMoved ].freeze

  # @return [Hash{String => Hash}] unit_id => allocation, role, provider, since and changed_on (ISO dates)
  attr_reader :memberships

  # @return [Hash{String => String}] unit_id => the last day of its last ended membership
  attr_reader :ends

  # The person's memberships as their stream knew them up to and including `event`.
  #
  # @param event [RubyEventStore::Event] a membership event already in the person's stream
  # @return [OrgGraph::MembershipFold]
  def self.through(event)
    earlier = Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(event.data[:person_id]))
                   .of_type(EVENTS).to(event.event_id).to_a
    new.tap { |fold| (earlier << event).each { fold.apply(it) } }
  end

  # @param memberships [Hash{String => Hash}] the state to continue from
  def initialize(memberships = {})
    @memberships = memberships
    @ends = {}
    @log = []
  end

  # @param event [RubyEventStore::Event] a membership event
  # @return [void]
  def apply(event)
    withdrawn = withdrawn_by(event)
    return step(@log.push(event).last) unless withdrawn

    @log.delete(withdrawn)
    @memberships, @ends = {}, {}
    @log.each { step(it) }
  end

  private

  def withdrawn_by(event)
    id = event.data[:changed_back_id]
    original = id.present? && @log.find { it.event_id == id }
    original if original && original.data[:effective_on].to_s == event.data[:effective_on].to_s
  end

  def step(event)
    data = event.data
    case event
    when OrgGraph::Events::MembershipSet then set(data)
    when OrgGraph::Events::MembershipEnded then finish(data[:unit_id], data[:effective_on])
    when OrgGraph::Events::MembershipMoved then move(data)
    end
  end

  def set(data)
    current = @memberships[data[:unit_id]] || {}
    on = data[:effective_on].to_s
    terms = current[:changed_on].to_s > on ? current : data
    @memberships[data[:unit_id]] = terms.slice(:allocation, :role, :provider).merge(
      since: [ current[:since], on ].compact.min, changed_on: [ current[:changed_on], on ].compact.max
    )
  end

  def finish(unit_id, on)
    @ends[unit_id] = on.to_s
    @memberships.delete(unit_id)
  end

  def move(data)
    on = data[:effective_on].to_s
    since = finish(data[:from_unit_id], on)&.fetch(:since) || on
    @memberships[data[:unit_id]] = data.slice(:allocation, :role, :provider).merge(since: since, changed_on: on)
  end
end
