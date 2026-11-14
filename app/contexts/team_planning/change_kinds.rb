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

  # The person whose key seals a note held apart from its change, in a pin,
  # a {TeamPlanning::Events::ChangeNoted} or a read model's row: the subject,
  # when its facet's kinds are {TeamPlanning::Events::Change.about_a_person},
  # so the note keeps the key its change has. Nil seals under the plan's key.
  NOTED_PERSON = ->(data) { data[:subject_id] if about_a_person?(data[:facet]) }

  # @return [Array<Class<TeamPlanning::Events::Change>>] sorted by name
  def self.all
    Rails.autoloaders.main.eager_load_dir(EVENTS)
    TeamPlanning::Events::Change.descendants.select { it.name&.start_with?("TeamPlanning::Events::") }.sort_by(&:name)
  end

  # Kinds may share a facet, as PositionSet and PositionClosed do, so the
  # last change there wins whichever kind it is.
  #
  # @param facet [String] the second half of a change's key
  # @return [Array<Class<TeamPlanning::Events::Change>>] every kind that holds it, sorted by name
  # @raise [TeamPlanning::Error] when no kind holds it
  def self.holding(facet)
    all.select { it.holds?(facet.to_s) }.presence || raise(TeamPlanning::Error, "No kind of change holds #{facet}")
  end

  # Kinds that share a facet share a subject, so they agree.
  #
  # @param facet [String]
  # @return [Boolean] whether a change that holds the facet is about a person
  # @raise [TeamPlanning::Error] when no kind holds it
  def self.about_a_person?(facet) = holding(facet).all?(&:about_a_person?)
end
