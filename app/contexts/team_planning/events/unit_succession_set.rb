# frozen_string_literal: true

# Which units carry on from which in a scenario: a split, a merge or a
# replacement. The subject is a succession id the plan mints. Retiring the
# predecessors is a {UnitRetired} each, written alongside.
#
# @!attribute [r] data
#   @return [Hash] the fields every {Change} holds, plus:
#   @option data [Array<String>] :predecessor_ids sorted
#   @option data [Array<String>] :successor_ids sorted
class TeamPlanning::Events::UnitSuccessionSet < TeamPlanning::Events::Change
  def self.facet = "succession"

  # @param data [Hash]
  # @return [Array<String>] the units on both sides
  def self.refers_to(data) = Array(data[:predecessor_ids]) + Array(data[:successor_ids])

  # @param end_state [Hash] `{ predecessor_ids:, successor_ids: }`
  # @return [Hash]
  # @raise [TeamPlanning::Error] for an empty side, an id that isn't one, or a unit on both sides
  def self.end_state(end_state)
    predecessor_ids = ids!(end_state[:predecessor_ids], "predecessor")
    successor_ids = ids!(end_state[:successor_ids], "successor")
    raise TeamPlanning::Error, "A unit can't succeed itself" if predecessor_ids.intersect?(successor_ids)

    { predecessor_ids:, successor_ids: }
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map] with this succession in place of any earlier one
  def self.apply_to(map, data)
    succession = TeamPlanning::Baseline::Succession.new(id: data[:subject_id], predecessor_ids: data[:predecessor_ids],
                                                        successor_ids: data[:successor_ids])
    map.with(successions: map.successions.reject { it.id == succession.id } + [ succession ])
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param subject_id [String]
  # @return [Hash, nil] the succession's two sides, nil when the map has none by that id
  def self.read_from(map, subject_id:, facet: self.facet)
    map.successions.find { it.id == subject_id }&.to_h&.slice(:predecessor_ids, :successor_ids)
  end

  # The Org Graph mints its own succession ids, so a planned succession is
  # found by its predecessors. Every succession that shares one is joined, as
  # the Org Graph may record a merge in parts.
  #
  # @param map [TeamPlanning::Baseline::Map] read off the Org Graph
  # @param change [TeamPlanning::Events::UnitSuccessionSet]
  # @return [Hash, nil] their two sides, nil when none shares a predecessor
  def self.read_org_graph(map, change)
    met = map.successions.select { it.predecessor_ids.intersect?(change.data[:predecessor_ids]) }
    return if met.empty?

    { predecessor_ids: met.flat_map(&:predecessor_ids).uniq.sort, successor_ids: met.flat_map(&:successor_ids).uniq.sort }
  end

  def self.ids!(values, what)
    ids = Array(values).map { TeamPlanning::Events::UnitSet.id_or_nil(it, what) }.compact.uniq.sort
    raise TeamPlanning::Error, "A succession needs at least one #{what}" if ids.empty?

    ids
  end
  private_class_method :ids!
end
