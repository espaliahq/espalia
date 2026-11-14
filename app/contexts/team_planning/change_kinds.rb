# frozen_string_literal: true

# Every kind of {TeamPlanning::Events::Change} a plan stream can hold, so the
# overrides projection subscribes to each and replays them. A kind is any
# Change subclass in app/contexts/team_planning/events, so adding one touches
# only its own file.
#
# The projection subscribes in a to_prepare block, which production runs
# before it eager-loads, so an `inherited` hook alone would find nothing
# then. Loading the directory first makes the answer the same at boot, in
# development and in tests.
module TeamPlanning::ChangeKinds
  EVENTS = Rails.root.join("app/contexts/team_planning/events").to_s.freeze

  # @return [Array<Class<TeamPlanning::Events::Change>>] sorted by name
  def self.all
    Rails.autoloaders.main.eager_load_dir(EVENTS)
    TeamPlanning::Events::Change.descendants.select { it.name&.start_with?("TeamPlanning::Events::") }.sort_by(&:name)
  end

  # @param facet [String] the second half of a change's key
  # @return [Class<TeamPlanning::Events::Change>]
  # @raise [TeamPlanning::Error] when no kind holds it
  def self.holding(facet) = all.find { it.holds?(facet.to_s) } || raise(TeamPlanning::Error, "No kind of change holds #{facet}")
end
