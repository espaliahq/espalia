# frozen_string_literal: true

# Which budget lines a position draws on, in place of the line derived from
# its cost centre ([#345](https://github.com/espaliahq/espalia/issues/345)).
# The exception only: a position funded from another cost centre, or split
# across lines. Each draw names a line and its share, and the shares sum to 1.
#
# A line the scenario no longer holds leaves the change standing, and
# {TeamPlanning::Attention} flags it rather than dropping it.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :subject_id the position's id
#   @option data [Array<Hash>] :draws each `{ budget_line_id:, share: }`, the share a decimal string
#   Plus {TeamPlanning::Events::Change::FIELDS}.
#
class TeamPlanning::Events::PositionFundingSet < TeamPlanning::Events::Change
  MAX_DRAWS = 10
  ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  SHARE = /\A(0\.\d+|1(\.0+)?)\z/

  # @return [String]
  def self.facet = "funding"

  # @param end_state [Hash] `{ draws: [{ budget_line_id:, share: }] }`; a lone draw's share may be left out
  # @return [Hash] `{ draws: }`, ids downcased and shares as decimal strings
  # @raise [TeamPlanning::Error] for no draws, too many, a line named twice, or shares that aren't
  #   each above 0 and together 1
  def self.end_state(end_state)
    draws = Array(end_state.to_h.symbolize_keys[:draws]).map { draw!(it) }
    raise TeamPlanning::Error, "Funding names at least one budget line" if draws.empty?
    raise TeamPlanning::Error, "Funding names at most #{MAX_DRAWS} budget lines" if draws.size > MAX_DRAWS

    draws = draws.map { |draw| { budget_line_id: line_id!(draw[:budget_line_id]), share: share!(draw[:share], lone: draws.one?) } }
    raise TeamPlanning::Error, "Funding names each budget line once" unless draws.map { it[:budget_line_id] }.uniq.size == draws.size
    raise TeamPlanning::Error, "The shares add up to 1" unless draws.sum(0r) { Rational(it[:share]) } == 1

    { draws: }
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map]
  def self.apply_to(map, data)
    map.with(fundings: map.fundings.merge(data[:subject_id] => data[:draws].map { it.to_h.symbolize_keys }))
  end

  # @return [Hash, nil] the draws the map holds for the position, for pinning and comparing with a parent
  def self.read_from(map, subject_id:, facet: self.facet)
    draws = map.fundings[subject_id] or return nil

    { draws: draws.map { it.slice(:budget_line_id, :share) } }
  end

  def self.draw!(value)
    value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
    raise TeamPlanning::Error, "Each draw names a budget line by its id" unless value.is_a?(Hash)

    value.symbolize_keys
  end

  def self.line_id!(value)
    id = value.to_s.strip.downcase
    raise TeamPlanning::Error, "Each draw names a budget line by its id" unless id.match?(ID)

    id
  end

  def self.share!(value, lone:)
    return "1" if lone && value.blank?

    share = value.to_s.strip
    raise TeamPlanning::Error, "Each share is a decimal above 0 and at most 1, such as \"0.5\"" unless share.match?(SHARE) && Rational(share).positive?

    share
  end

  private_class_method :draw!, :line_id!, :share!
end
