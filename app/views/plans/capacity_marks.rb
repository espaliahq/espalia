# frozen_string_literal: true

# What the scenario map shows of capacity
# ([#296](https://github.com/espaliahq/espalia/issues/296)): a strip of totals,
# a total per unit and a figure per place, each beside the baseline's. It reads
# two `team_planning_capacity` payloads, the scenario's and the baseline's,
# and keeps their decimal strings exact: only {Format} rounds, as it draws.
#
# Totals stay per model, so two models sit side by side and never sum.
class Views::Plans::CapacityMarks
  # Rounds only for display; the sums before it stay exact.
  module Format
    module_function

    # @param amount [BigDecimal]
    # @param unit [String] what follows the number, such as "u"
    # @return [String]
    def amount(amount, unit) = "#{sprintf('%.1f', amount.round(1))}#{suffix(unit)}"

    # @return [String, nil] nil when the change rounds to nothing
    def change(amount, unit)
      rounded = amount.round(1)
      return if rounded.zero?

      "#{rounded.negative? ? '−' : '+'}#{sprintf('%.1f', rounded.abs)}#{suffix(unit)}"
    end

    # A working step, to two places, so a share of a third still reads.
    #
    # @param amount [BigDecimal]
    # @return [String]
    def step(amount) = amount.round(2).to_s("F").delete_suffix(".0")

    # @param total [Total]
    # @return [Array<Array(String, String)>] each part's label and figure; none when the total has no parts
    def parts(total)
      return [] unless total.parts

      actual, planned, forecast = total.parts.values_at(:actual, :planned, :forecast)
      forecast = change(forecast, total.unit)
      [ [ "Actual", amount(actual, total.unit) ], [ "Planned", change(planned, total.unit) || amount(planned, total.unit) ],
        ([ "Forecast", forecast ] if forecast) ].compact
    end

    def suffix(unit) = unit.length == 1 ? unit : " #{unit}"
  end

  # @!attribute model [String]
  # @!attribute unit [String]
  # @!attribute amount [BigDecimal]
  # @!attribute change [BigDecimal] against the baseline
  # @!attribute parts [Hash{Symbol => BigDecimal}, nil] actual, planned and forecast, which add up to the amount
  Total = Data.define(:model, :unit, :amount, :change, :parts) do
    def initialize(parts: nil, **) = super
  end

  # @param scenario [Hash] `team_planning_capacity` for the scenario shown
  # @param baseline [Hash] `team_planning_capacity` for the plan's baseline
  # @param names [Hash{String => String}] person id => name, from the map
  # @param live_unit_ids [Array<String>, nil] the units the map shows, so an
  #   unassigned row finds a place left in a retired unit
  def initialize(scenario:, baseline:, names:, live_unit_ids: nil)
    @scenario = scenario
    @baseline = baseline
    @names = names
    @live_unit_ids = live_unit_ids&.to_set
  end

  # Today counts too, so a scenario that empties a model still shows the drop.
  # A model no longer registered is missing from `models`, but its place
  # still had one chosen, and the strip lists it as unclassified.
  #
  # @return [Boolean] whether any place, here or on Today, has a model chosen
  def measured? = models.any? || [ @scenario, @baseline ].any? { chosen?(it) }

  # @return [Boolean] whether the scenario shown is the baseline itself
  def baseline? = @scenario[:scenario_id] == @scenario[:plan_id]

  # @return [Array<Total>] the scenario's, one per model
  def totals = compare(@scenario[:totals], @baseline[:totals], @scenario[:parts])

  # Figures arrive to 20 significant digits, so three thirds can sum a hair
  # under one; a remainder that rounds to nothing on screen is that, not a place.
  #
  # @return [Array<Total>] what counts for the scenario but in no unit on the map
  def outside_units
    totals.filter_map do |total|
      inside = @scenario[:units].sum { exact(it[:totals][total.model]) }
      rest = total.amount - inside
      total.with(amount: rest, change: 0, parts: nil) unless rest.round(1).zero?
    end
  end

  # @return [Array<Hash>] each place that counts for no capacity, from the payload
  def unclassified = @scenario[:unclassified]

  # @param seat_id [String]
  # @return [String] a person's name, or what an open position is
  def seat_name(seat_id, kind) = kind == "person" ? @names.fetch(seat_id, Person::FORMER_MEMBER) : "An open position"

  # @return [#call] unit hash => its totals
  def unit_marks
    lambda do |unit|
      return [] unless measured?

      row = unit_rows(@scenario)[unit[:id]]
      [ Views::Plans::CapacityUnitTotal.new(totals: compare(row&.dig(:totals), unit_rows(@baseline)[unit[:id]]&.dig(:totals), row&.dig(:parts)),
                                            baseline: baseline?) ]
    end
  end

  # @return [#call] (person hash, place hash or nil) => the place's figure
  def person_marks
    lambda do |person, place|
      priced = place_of(person[:id], place)
      priced ? [ figure(priced, "#{@names.fetch(person[:id], Person::FORMER_MEMBER)}'s capacity") ] : []
    end
  end

  # @return [#call] position hash => the figure for the FTE it leaves open, as a filled place's is shown
  def position_marks
    lambda do |position|
      priced = seats[position[:position_id]]&.dig(:places, 0)
      priced ? [ figure(priced, "The open position's capacity") ] : []
    end
  end

  # @param model [String]
  # @return [String] what follows a figure in the model
  def unit_of(model) = models.dig(model, :symbol) || model

  # @param model [String]
  # @return [String, nil]
  def description_of(model) = models.dig(model, :description)

  # @return [Hash{String => String}] who each working step names
  def subject_names = @scenario[:names]

  private

  def chosen?(payload) = payload[:seats].any? { |seat| seat[:places].any? { it[:model] } }

  def models = @models ||= @baseline[:models].merge(@scenario[:models])

  def figure(priced, label) = Views::Plans::CapacityFigure.new(place: priced, marks: self, label:)

  def compare(scenario, baseline, parts = nil)
    scenario ||= {}
    baseline ||= {}
    (scenario.keys | baseline.keys).sort.map do |model|
      amount = exact(scenario[model])
      Total.new(model:, unit: unit_of(model), amount:, change: amount - exact(baseline[model]), parts: parts && parts.transform_values { exact(it[model]) })
    end
  end

  def unit_rows(payload) = (@unit_rows ||= {})[payload.object_id] ||= payload[:units].index_by { it[:unit_id] }

  def seats = @seats ||= @scenario[:seats].index_by { it[:seat_id] }

  # A place in a position is the position's; anyone else's is their unit's.
  # The map lists someone as unassigned when no unit they're in is live, so
  # their row takes a place in no unit or in one the map no longer shows.
  def place_of(person_id, place)
    seat = seats[person_id]
    return unless seat && measured?

    seat[:places].find do |priced|
      place ? priced[:position_id] == place[:position_id] && (place[:position_id] || priced[:unit_id] == place[:unit_id]) : off_the_map?(priced)
    end
  end

  def off_the_map?(priced) = priced[:unit_id].nil? || @live_unit_ids&.exclude?(priced[:unit_id])

  def exact(value) = value.nil? ? BigDecimal(0) : BigDecimal(value)
end
