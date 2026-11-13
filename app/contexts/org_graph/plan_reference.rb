# frozen_string_literal: true

# The plan change an Org Graph command was applied from: the plan's id and the
# change's id. The Org Graph stores both and never reads them. A command given
# none is a direct edit, and so is every event written before this existed.
#
# Prepended to each aggregate, it writes the reference onto every event a
# command applies, so no command can drop it.
OrgGraph::PlanReference = Data.define(:plan_id, :plan_change_id) do
  # @param plan_id [String, nil]
  # @param plan_change_id [String, nil]
  def initialize(plan_id: nil, plan_change_id: nil)
    super
  end

  # Splits a command's options into its plan reference and the rest.
  #
  # @param options [Hash]
  # @return [Array(OrgGraph::PlanReference, Hash)]
  def self.extract(options)
    [ new(**options.slice(*members)), options.except(*members) ]
  end

  # @return [Hash] the ids given, without the blank ones
  def to_h = super.compact_blank
end

# Stamps the current plan reference on each event the aggregate applies.
module OrgGraph::PlanReference::Stamping
  # Runs the block with `reference` stamped on every event it applies.
  #
  # @param reference [OrgGraph::PlanReference]
  def within_plan(reference)
    @plan_reference = reference.to_h.presence
    yield self
  ensure
    @plan_reference = nil
  end

  # @see AggregateRoot#apply
  def apply(*events)
    return super unless @plan_reference

    super(*events.map { |event| event.class.new(event_id: event.event_id, metadata: event.metadata.to_h,
                                                data: event.data.merge(@plan_reference)) })
  end
end
