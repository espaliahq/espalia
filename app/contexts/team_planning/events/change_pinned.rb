# frozen_string_literal: true

# A scenario took the end state it inherited for one facet of one subject as
# its own, so a later change in its parent no longer reaches it. From then on
# the pin is the scenario's change for that facet, of the kind it names.
#
# Reconcile (4.5) keeps an inherited change over a conflict as a pin.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id
#   @option data [String] :subject_id
#   @option data [String] :facet the second half of the change's key
#   @option data [String] :kind the {TeamPlanning::Events::Change} subclass
#   @option data [Hash] :end_state as that kind stores it
#   @option data [String, nil] :pinned_from_scenario_id the scenario whose change it kept; nil for the baseline
#   @option data [String, nil] :pinned_from_event_id that change's event id; nil for the baseline
#   @option data [String] :pinned_by_id person_id of the actor
#   @option data [Shreddable::Value, nil] :note why the scenario keeps it, sealed under the subject's key,
#     as a change of its kind seals one; absent when there is none, and never part of the end state
#   @option data [Hash, nil] :settles for a pin that kept the plan over a conflict an update to today carried
#     forward, `since` and `choice`, as {TeamPlanning::Events::Change} holds them; absent for an ordinary pin
#
class TeamPlanning::Events::ChangePinned < RubyEventStore::Event
  extend Shreddable

  shreddable :note, by: :person, person: TeamPlanning::ChangeKinds::NOTED_PERSON
end
