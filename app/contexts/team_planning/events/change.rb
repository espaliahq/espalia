# frozen_string_literal: true

# A change a scenario makes: the end state of one facet of one subject. A
# facet is the part of a subject one kind of change sets, so a person's level
# and their assignment never compete. Each kind subclasses this, names its
# {.facet} and says how its end state lands on a resolved map.
#
# A change never refers to the content of its parent scenario, so the same
# change resolves over any base.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :plan_id
#   @option data [String] :scenario_id
#   @option data [String] :subject_id an Org Graph id, or one the plan minted
#   @option data [String] :set_by_id person_id of the actor
#   The kind adds its end state alongside these.
#
class TeamPlanning::Events::Change < RubyEventStore::Event
  # The fields every change holds, which no end state may set.
  FIELDS = %i[plan_id scenario_id subject_id set_by_id].freeze

  # @return [String] the part of a subject this kind sets
  def self.facet = raise(NotImplementedError, "#{name} must name its facet")

  # @param end_state [Hash] the kind's own fields, as the caller gave them
  # @return [Hash] the fields as stored
  # @raise [TeamPlanning::Error] when the end state is not one this kind can hold
  def self.end_state(end_state) = end_state

  # Kinds land in the order they were made, not by kind, so this must not
  # depend on another kind having landed first. Checks across kinds, such as
  # a misfit, run on the resolved map instead.
  #
  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash] the stored event data
  # @return [TeamPlanning::Baseline::Map] the map with this end state in place
  def self.apply_to(map, data) = raise(NotImplementedError, "#{name} must say how it lands on a map")

  # The subject whose facet of this kind an Org Graph change moves, for the
  # drift report. A kind that meets no Org Graph change keeps the default.
  #
  # @param change [OrgGraph::ChangesBetween::Change]
  # @return [String, nil] the subject's id, nil when it moves none
  def self.subject_moved_by(change) = nil

  # @return [Boolean] whether this kind names its facet and says how it lands
  def self.complete? = %i[facet apply_to].all? { method(it).owner != TeamPlanning::Events::Change.singleton_class }

  # @return [Array(String, String)] what the last change wins over
  def key = [ data[:subject_id], self.class.facet ]
end
