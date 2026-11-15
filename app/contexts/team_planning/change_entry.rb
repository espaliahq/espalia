# frozen_string_literal: true

# What one plan event did to one facet of one subject in a scenario, as a read
# model records it. The overrides and history projections both read events
# through it, so they agree on what each event did.
#
# A shreddable value never leaves the event: {#end_state} holds only the
# fields in clear, and {#sealed_fields} names the rest. {#note} is the
# planner's note as the event holds it, sealed; a note entry names the
# change it notes in {#noted_event_id}.
#
# An update to today changes no facet, but the history keeps it as a
# baseline entry, `rebase`, with the old and new base and the keys of the
# conflicts it carried forward. A set or pin that settled one of those
# conflicts holds {#settles}: the conflict's since and the choice made.
TeamPlanning::ChangeEntry = Data.define(
  :event_id, :plan_id, :scenario_id, :subject_id, :facet, :action, :kind, :end_state, :sealed_fields,
  :actor_id, :at, :pinned_from_scenario_id, :pinned_from_event_id, :reverses_event_id, :note,
  :noted_event_id, :settles
) do
  # @param event [RubyEventStore::Event]
  # @return [TeamPlanning::ChangeEntry, nil] nil for an event that changes no facet
  def self.from(event)
    fields = fields_of(event) or return nil

    new(event_id: event.event_id, plan_id: event.data[:plan_id], scenario_id: event.data[:scenario_id] || event.data[:plan_id],
        at: event.timestamp, subject_id: nil, facet: nil, kind: nil, end_state: nil, sealed_fields: [],
        pinned_from_scenario_id: nil, pinned_from_event_id: nil, reverses_event_id: nil, note: nil, noted_event_id: nil,
        settles: event.data[:settles]&.to_h&.stringify_keys, **fields)
  end

  def self.fields_of(event)
    data = event.data
    case event
    when TeamPlanning::Events::Change
      { action: "set", subject_id: data[:subject_id], facet: event.key.last, kind: event.class.name,
        actor_id: data[:set_by_id], note: data[:note], **split(data.except(*TeamPlanning::Events::Change::FIELDS)) }
    when TeamPlanning::Events::ChangePinned
      { action: "pin", **data.slice(:subject_id, :facet, :kind, :pinned_from_scenario_id, :pinned_from_event_id),
        actor_id: data[:pinned_by_id], note: data[:note], **split(data[:end_state].to_h) }
    when TeamPlanning::Events::ChangeCleared
      { action: "clear", **data.slice(:subject_id, :facet), actor_id: data[:cleared_by_id] }
    when TeamPlanning::Events::ChangeUndone
      { action: "undo", **data.slice(:subject_id, :facet), reverses_event_id: data[:undone_event_id], actor_id: data[:undone_by_id] }
    when TeamPlanning::Events::ChangeNoted
      { action: "note", **data.slice(:subject_id, :facet, :noted_event_id, :note), actor_id: data[:noted_by_id] }
    when TeamPlanning::Events::PlanRebased
      { action: "rebase", end_state: data.slice(:base_on, :previous_base_on, :conflicts).deep_stringify_keys, actor_id: data[:rebased_by_id] }
    when TeamPlanning::Events::ChangeRedone
      { action: "redo", **data.slice(:subject_id, :facet), reverses_event_id: data[:redone_event_id], actor_id: data[:redone_by_id] }
    end
  end

  def self.split(end_state)
    sealed, clear = end_state.partition { |_, value| value.is_a?(Shreddable::Value) }
    { end_state: clear.to_h, sealed_fields: sealed.map { it.first.to_s } }
  end
  private_class_method :fields_of, :split

  # What an end state says once a split moves its change from one scenario to
  # another, by the rule of the change's kind.
  #
  # @param kind [String, nil] the change's class name
  # @param end_state [Hash, nil]
  # @param from [String]
  # @param to [String]
  # @return [Hash, nil]
  def self.moved_end_state(kind, end_state, from:, to:)
    klass = kind&.safe_constantize
    return end_state unless end_state && klass.respond_to?(:moved_end_state)

    klass.moved_end_state(end_state.to_h.symbolize_keys, from:, to:)
  end

  # @param to [String] the agreed part a split moves this entry's change to
  # @return [TeamPlanning::ChangeEntry]
  def moved_to(to) = with(scenario_id: to, end_state: self.class.moved_end_state(kind, end_state, from: scenario_id, to:))

  # @return [Boolean] whether it sets an end state: a set or a pin
  def sets? = %w[set pin].include?(action)

  # @return [Boolean] whether it rewrites the note on another entry
  def notes? = action == "note"

  # @return [Boolean] whether it reverses another entry
  def reverses? = !reverses_event_id.nil?
end
