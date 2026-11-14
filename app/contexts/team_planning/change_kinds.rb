# frozen_string_literal: true

# Every kind of {TeamPlanning::Events::Change} a plan stream can hold, so the
# overrides projection subscribes to each and replays them. A new kind adds
# itself here; test/contexts/team_planning/change_kinds_test.rb fails until
# it does.
module TeamPlanning::ChangeKinds
  ALL = %w[TeamPlanning::Events::RuleSet].freeze

  # @return [Array<Class<TeamPlanning::Events::Change>>]
  def self.all = ALL.map(&:constantize)

  # @param facet [String] the second half of a change's key
  # @return [Class<TeamPlanning::Events::Change>]
  # @raise [TeamPlanning::Error] when no kind holds it
  def self.holding(facet) = all.find { it.holds?(facet.to_s) } || raise(TeamPlanning::Error, "No kind of change holds #{facet}")
end
