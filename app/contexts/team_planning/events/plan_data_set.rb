# frozen_string_literal: true

# A value the plan holds about a person in place of the Org Graph's, such as
# a level the HRIS has wrong or an FTE about to change. Each field is its own
# facet, so a corrected level and a corrected FTE both land. The value seals
# under the person's key in the plan.
#
# A hire the plan adds is a {PlaceholderSet}, since it seals under the plan's
# key instead.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :subject_id the person's id
#   @option data [String] :field one of {FIELDS}
#   @option data [Shreddable::Value] :value
#   Plus {TeamPlanning::Events::Change::FIELDS}.
#
class TeamPlanning::Events::PlanDataSet < TeamPlanning::Events::Change
  extend Shreddable
  extend TeamPlanning::Events::SealedChange

  shreddable :value, by: :person, person: :subject_id

  # The fields a plan can hold for a person, each with how its value is checked.
  FIELDS = {
    "level" => ->(value) { value.to_s.strip.presence or raise TeamPlanning::Error, "A level names the level" },
    "fte" => ->(value) { TeamPlanning::Events::PlanDataSet.fte!(value) }
  }.freeze

  # The Org Graph fact each field lives in.
  FACTS = { "level" => "level", "fte" => "employment" }.freeze

  # @return [String]
  def self.facet = "data"

  # @param end_state [Hash] `{ field:, value: }`
  # @return [Hash]
  # @raise [TeamPlanning::Error] for a field the plan can't hold, or a value that field can't take
  def self.end_state(end_state)
    field = end_state[:field].to_s
    check = FIELDS.fetch(field) { raise TeamPlanning::Error, "A plan holds a person's #{FIELDS.keys.to_sentence(two_words_connector: ' or ', last_word_connector: ' or ')}, not #{field.presence || 'nothing'}" }

    { field:, value: check.call(end_state[:value]) }
  end

  # @param value [Object]
  # @return [Float]
  # @raise [TeamPlanning::Error] unless above 0 and at most 1
  def self.fte!(value)
    fte = Float(value, exception: false)
    return fte if fte&.positive? && fte <= 1

    raise TeamPlanning::Error, "An FTE is above 0 and at most 1"
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map]
  def self.apply_to(map, data)
    on_person(map, data) { it.with(plan_data: it.plan_data.merge(data[:field].to_sym => data[:value])) }
  end

  # Off the plan's map, the plan's value; off today's, the Org Graph's.
  #
  # @param map [TeamPlanning::Baseline::Map]
  # @param subject_id [String]
  # @param facet [String]
  # @return [Hash, nil]
  def self.read_from(map, subject_id:, facet: self.facet)
    field = facet.delete_prefix("#{self.facet}:")
    person = map.people.find { it.id == subject_id } or return nil

    { field:, value: person.plan_data[field.to_sym] || person.public_send(field) }
  end

  # @param change [OrgGraph::ChangesBetween::Change]
  # @return [String, nil] the person, when the Org Graph changes a field the plan can hold
  def self.subject_moved_by(change) = (change.person_id if change.kind == :fact_changed && FACTS.value?(change.fact))

  # @param facet [String]
  # @return [Boolean]
  def self.holds?(facet) = facet.start_with?("#{self.facet}:")

  # @return [Array(String, String)]
  def key = [ data[:subject_id], "#{self.class.facet}:#{data[:field]}" ]
end
