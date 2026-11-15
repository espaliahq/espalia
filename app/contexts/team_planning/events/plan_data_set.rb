# frozen_string_literal: true

# A value the plan holds about a person in place of the Org Graph's, such as
# a level the HRIS has wrong or an FTE about to change, or one the Org Graph
# doesn't hold: their actual pay. Each field is its own facet, so a corrected
# level and a corrected FTE both land. The value seals under the person's key
# in the plan.
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
  about_a_person

  # The fields a plan can hold for a person, each with how its value is checked.
  FIELDS = {
    "level" => ->(value) { value.to_s.strip.presence or raise TeamPlanning::Error, "A level names the level" },
    "fte" => ->(value) { TeamPlanning::Events::PlanDataSet.fte!(value) },
    "pay" => ->(value) { TeamPlanning::Events::PlanDataSet.pay!(value) }
  }.freeze

  # The Org Graph fact each field lives in. Pay lives in none.
  FACTS = { "level" => "level", "fte" => "employment" }.freeze

  # The facet pay is held under, which only a member with the see-pay right may change.
  PAY_FACET = "data:pay"

  # Whether a pay amount is the person's pay as it is, already pro-rated for
  # a part-timer, or a full-time figure that their FTE scales.
  PAY_BASES = %w[actual full_time].freeze

  PAY_AMOUNT = /\A\d{1,12}(?:\.\d{1,4})?\z/

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

  # Checks a pay value without ever naming it, so no error carries pay.
  #
  # @param value [Hash] `amount`, `currency`, `period` and `basis`
  # @return [Hash] with string keys, the amount as a plain decimal string
  # @raise [TeamPlanning::Error] for a part missing or that can't be pay
  def self.pay!(value)
    pay = value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
    amount = pay["amount"].to_s.strip
    raise TeamPlanning::Error, "A pay amount is a number above 0, with at most 4 decimal places" unless amount.match?(PAY_AMOUNT) && amount.to_r.positive?

    currency = Currency::NORMALIZE.call(pay["currency"].to_s)
    raise TeamPlanning::Error, "A pay currency is a three-letter ISO 4217 code" unless Currency::CODES.include?(currency)
    raise TeamPlanning::Error, "A pay period is year, month or hour" unless PayBand::PERIODS.include?(pay["period"])
    raise TeamPlanning::Error, "Say whether the amount is the person's actual pay or a full-time figure: basis actual or full_time" unless PAY_BASES.include?(pay["basis"])
    raise TeamPlanning::Error, "An hourly amount is a rate, which FTE scales, so its basis is full_time" if pay["period"] == "hour" && pay["basis"] == "actual"

    { "amount" => BigDecimal(amount).to_s("F").delete_suffix(".0"), "currency" => currency, "period" => pay["period"], "basis" => pay["basis"] }
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map]
  def self.apply_to(map, data)
    on_person(map, data) { it.with(plan_data: it.plan_data.merge(data[:field].to_sym => data[:value])) }
  end

  # Off the plan's map, the plan's value; off today's, the Org Graph's, for
  # a field it holds.
  #
  # @param map [TeamPlanning::Baseline::Map]
  # @param subject_id [String]
  # @param facet [String]
  # @return [Hash, nil]
  def self.read_from(map, subject_id:, facet: self.facet)
    field = facet.delete_prefix("#{self.facet}:")
    person = map.people.find { it.id == subject_id } or return nil

    { field:, value: person.plan_data[field.to_sym] || (person.public_send(field) if FACTS.key?(field)) }
  end

  # @param change [OrgGraph::ChangesBetween::Change]
  # @return [String, nil] the person, when the Org Graph changes a field the plan can hold
  def self.subject_moved_by(change) = (change.person_id if change.kind == :fact_changed && FACTS.value?(change.fact))

  # @param planned [PlanDataSet]
  # @param change [OrgGraph::ChangesBetween::Change]
  # @return [Boolean] whether the change moves the field this one holds
  def self.moved_by?(planned, change) = super && FACTS[planned.data[:field]] == change.fact

  # Pay is a field the Org Graph never holds.
  #
  # @param change [PlanDataSet]
  # @return [Boolean]
  def self.tracks?(change) = super && FACTS.key?(change.data[:field].to_s)

  # @param facet [String]
  # @return [Boolean]
  def self.holds?(facet) = facet.start_with?("#{self.facet}:") && FIELDS.key?(facet.delete_prefix("#{self.facet}:"))

  # @return [Array(String, String)]
  def key = [ data[:subject_id], "#{self.class.facet}:#{data[:field]}" ]
end
