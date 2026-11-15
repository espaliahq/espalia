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
#   @option data [Shreddable::Value, nil] :note why the planner made it, sealed under its subject's key:
#     the person's in the plan for a kind {.about_a_person}, else the plan's; absent when there is none. It is no part of the end state, so it never decides how a change
#     resolves, compares or reads against the Org Graph.
#   The kind adds its end state alongside these.
#
class TeamPlanning::Events::Change < RubyEventStore::Event
  extend Shreddable

  shreddable :note, by: :plan

  # The fields every change may hold, which no end state may set.
  FIELDS = %i[plan_id scenario_id subject_id set_by_id note].freeze

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

  # Reads this kind's end state for one subject back off a map, so a caller
  # can keep what a map already holds. The caller chooses the map: a pin
  # ([#239](https://github.com/espaliahq/espalia/issues/239)) reads the
  # parent's resolved map, and status per change
  # ([#235](https://github.com/espaliahq/espalia/issues/235)) a map built from
  # today's Org Graph. Applying an end state and reading it
  # back gives the same end state.
  #
  # @param map [TeamPlanning::Baseline::Map]
  # @param subject_id [String]
  # @param facet [String] the second half of the change's {#key}
  # @return [Hash, nil] the end state as {.end_state} stores it, or nil when the map doesn't hold the subject
  def self.read_from(map, subject_id:, facet: self.facet) = raise(NotImplementedError, "#{name} can't read its end state off a map")

  # The subject whose facet of this kind an Org Graph change moves, for the
  # drift report. A kind that meets no Org Graph change keeps the default.
  #
  # @param change [OrgGraph::ChangesBetween::Change]
  # @return [String, nil] the subject's id, nil when it moves none
  def self.subject_moved_by(change) = nil

  # @param planned [TeamPlanning::Events::Change] a change of this kind
  # @param change [OrgGraph::ChangesBetween::Change]
  # @return [Boolean] whether the Org Graph's change moves what the planned change holds
  def self.moved_by?(planned, change) = subject_moved_by(change) == planned.data[:subject_id]

  # Whether two end states of this kind are the same, as when one is read
  # off a map and the other was planned. They can differ in key type alone.
  #
  # @param left [Hash, nil]
  # @param right [Hash, nil]
  # @return [Boolean]
  def self.same_end_state?(left, right) = left.as_json == right.as_json

  # What a map read off the Org Graph holds for a planned change, read as this
  # kind reads its end state. A kind whose subject the Org Graph names with an
  # id of its own says how to find it.
  #
  # @param map [TeamPlanning::Baseline::Map]
  # @param change [Change]
  # @return [Hash, nil]
  def self.read_org_graph(map, change) = read_from(map, subject_id: change.data[:subject_id], facet: change.key.last)

  # Whether the Org Graph reads as a planned end state shows it, for status per
  # change. A kind whose end state names something only the plan holds says how
  # the Org Graph would show it.
  #
  # @param read [Hash, nil] the end state read off the Org Graph
  # @param planned [Hash, nil]
  # @param map [TeamPlanning::Baseline::Map] the plan's map the planned end state belongs to
  # @return [Boolean]
  def self.shows?(read, planned, map:) = same_end_state?(read, planned)

  # @return [Boolean] whether this kind seals a field of its end state, beyond the note any change may carry
  def self.seals_end_state? = (shreddable_fields.keys - FIELDS).any?

  # Declares this kind's subject a person, so its note seals under that
  # person's key in the plan and goes when they are forgotten.
  #
  # @return [void]
  def self.about_a_person = shreddable(:note, by: :person, person: :subject_id)

  # @return [Boolean] whether this kind's subject is a person
  def self.about_a_person? = shreddable_fields.dig(:note, :by) == :person

  # @return [Boolean] whether this kind names its facet and says how it lands
  def self.complete? = %i[facet apply_to].all? { overrides?(it) }

  # @return [Boolean] whether this kind can read its end state off a map
  def self.readable? = overrides?(:read_from)

  # @return [Boolean] whether the Org Graph can move this kind's facet, so it has a status per change
  def self.meets_org_graph? = overrides?(:subject_moved_by)

  # @return [Boolean] whether a change of this kind has a status: it reads its end state off a map,
  #   and the Org Graph either moves its facet or holds its subject under an id of its own
  def self.tracked? = readable? && (meets_org_graph? || overrides?(:read_org_graph))

  # @param change [Change] a change of this kind
  # @return [Boolean] whether the Org Graph could ever show this change, so it is held against it
  def self.tracks?(change) = tracked?

  # @param facet [String] the second half of a change's {#key}
  # @return [Boolean] whether a change of this kind can have that key
  def self.holds?(facet) = facet == self.facet

  def self.overrides?(method_name) = method(method_name).owner != TeamPlanning::Events::Change.singleton_class
  private_class_method :overrides?

  # @return [Array(String, String)] what the last change wins over
  def key = [ data[:subject_id], self.class.facet ]
end
