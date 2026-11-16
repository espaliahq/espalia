# frozen_string_literal: true

# The four numbers a planner compares for a scenario: what its budget lines
# approve, what its positions draw on them, what is left, and what no line
# covers ([#369](https://github.com/espaliahq/espalia/issues/369)).
#
# Money comes from the seat lines {TeamPlanning::Cost} prices, so it follows
# the caller's pay view, and draws come from {TeamPlanning::Funding}. Each
# priced seat in a position goes to the lines its position draws on, at each
# draw's share and for the days of the seat each line's period covers; the
# rest of it is unfunded, as is a seat in no position and any forecast row,
# which names none and counts as its kind prices it on either basis. So
# funded plus unfunded is the cost read's total, per currency, on an
# inclusive basis, and its base pay plus the forecast on a base-only one. A seat no band prices counts in head count
# and is listed under `unpriced`, with no money.
#
# Approved is a line's amount, made yearly, over the days its period overlaps
# the scenario's, out of a 365-day year as the cost read counts. A line with
# no amount approves none, never zero. Money keeps its currency: a line drawn
# on in another currency is flagged and never converted, and its remaining is
# in its own currency only. Only the grand totals convert, to the reference
# currency at the period's start.
#
# Lines and cost centres carry all four numbers; a line's cost centre is the
# one it was approved for. Units carry funded and unfunded only, as no line
# is approved for a unit. Unfunded money goes to the seat's own cost centre,
# and unfunded head count to the position's. A line or cost centre counts
# each position drawing on it once, at the FTE it draws; the plan's total
# counts the positions funded whole, as {TeamPlanning::Funding} does, so
# funded and unfunded add up to every position.
#
# The {TeamPlanning::RuleKinds::BudgetStrictness} rule says where the budget
# is held ([#384](https://github.com/espaliahq/espalia/issues/384)): each
# line, each cost centre or the organisation's total carries `over`, and the
# others carry none. A figure is over in a currency whose remaining, summed
# over its lines, is below zero, and over on heads when its remaining head
# count is. Money is never converted to judge it: a line drawn on in another
# currency is listed as mismatched, not counted for or against.
#
# @example
#   TeamPlanning::Budget.new(context:, plan:, scenario_id:).call.totals
class TeamPlanning::Budget
  # @!attribute positions [Integer]
  # @!attribute fte [Rational]
  Heads = Data.define(:positions, :fte) do
    # @return [Heads]
    def +(other) = Heads.new(positions: positions + other.positions, fte: fte + other.fte)
  end

  NO_HEADS = Heads.new(positions: 0, fte: 0r)

  # Whether a figure at the strictness rule's scope spends more than its budget.
  #
  # @!attribute money [Array<String>, nil] the currencies it is over in; nil when money isn't limited
  # @!attribute heads [Boolean, nil] whether its FTE drawn passes its head count; nil when heads aren't
  #   limited or no line states a head count
  # @!attribute mismatched [Array<String>] currencies its lines are drawn on in besides their own, never judged
  Over = Data.define(:money, :heads, :mismatched)

  # One budget line's four numbers.
  #
  # @!attribute line [TeamPlanning::Baseline::BudgetLine]
  # @!attribute approved [Rational, nil] in the line's currency over the overlap; nil with no amount
  # @!attribute funded [Hash{String => Rational}] currency => what its draws cost
  # @!attribute funded_heads [Heads] the positions drawing on it, and the FTE they draw
  # @!attribute remaining [Rational, nil] approved less funded in the line's currency
  # @!attribute remaining_head_count [Rational, nil] the head count less the FTE drawn
  # @!attribute mismatched [Array<String>] the other currencies its positions cost in
  # @!attribute over [Over, nil] when the strictness rule holds each line
  Line = Data.define(:line, :approved, :funded, :funded_heads, :remaining, :remaining_head_count, :mismatched, :over)

  # @!attribute approved [TeamPlanning::Cost::Sum]
  # @!attribute head_count [Rational, nil] nil when no line states one
  # @!attribute funded [TeamPlanning::Cost::Sum]
  # @!attribute funded_heads [Heads]
  # @!attribute remaining [TeamPlanning::Cost::Sum]
  # @!attribute remaining_head_count [Rational, nil]
  # @!attribute unfunded [TeamPlanning::Cost::Sum]
  # @!attribute unfunded_heads [Heads]
  # @!attribute over [Over, nil] when the strictness rule holds the budget at this figure
  Totals = Data.define(:approved, :head_count, :funded, :funded_heads, :remaining, :remaining_head_count, :unfunded, :unfunded_heads, :over)

  # @!attribute funded [TeamPlanning::Cost::Sum]
  # @!attribute funded_heads [Heads]
  # @!attribute unfunded [TeamPlanning::Cost::Sum]
  # @!attribute unfunded_heads [Heads]
  UnitTotals = Data.define(:funded, :funded_heads, :unfunded, :unfunded_heads)

  # A position with a seat no band prices.
  #
  # @!attribute position_id [String]
  # @!attribute unit_id [String, nil]
  # @!attribute reasons [Array<String>] {TeamPlanning::Cost::REASONS} keys
  # @!attribute budget_line_ids [Array<String>] the held lines it draws on
  Unpriced = Data.define(:position_id, :unit_id, :reasons, :budget_line_ids)

  # @!attribute basis [String] a {TeamPlanning::RuleKinds::BudgetBasis::BASES} entry
  # @!attribute strictness [Hash] the {TeamPlanning::RuleKinds::BudgetStrictness} value
  # @!attribute period [Range<Date>]
  # @!attribute pay_view [String] the cost read's
  # @!attribute reference_currency [String, nil]
  # @!attribute lines [Array<Line>] by line id
  # @!attribute cost_centres [Hash{String, nil => Totals}] nil for no cost centre
  # @!attribute units [Hash{String, nil => UnitTotals}] nil for a seat in no live unit, as the cost read files it
  # @!attribute totals [Totals]
  # @!attribute forecast [TeamPlanning::Cost::Sum] the unfunded part forecast rows add
  # @!attribute unpriced [Array<Unpriced>]
  Report = Data.define(:basis, :strictness, :period, :pay_view, :reference_currency, :lines, :cost_centres, :units, :totals, :forecast, :unpriced)

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String] a scenario, never the root, which has no period
  # @param repository [TeamPlanning::Repository]
  def initialize(context:, plan:, scenario_id:, repository: TeamPlanning::Repository.new)
    @context = context
    @plan = plan
    @scenario_id = scenario_id
    @repository = repository
  end

  # @return [Report]
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for the root, or a scenario the plan doesn't have
  def call
    aggregate = @repository.load_plan(@plan.id)
    funding = TeamPlanning::Funding.new(context: @context, plan: @plan, scenario_id: @scenario_id, repository: @repository, aggregate:).call
    cost = TeamPlanning::Cost.new(context: @context, plan: @plan, scenario_id: @scenario_id, repository: @repository, aggregate:).call
    @period = funding.period
    @reference = cost.reference_currency
    @factors = {}
    @inclusive = TeamPlanning::RuleKinds::BudgetBasis.inclusive?(funding.map.rule(TeamPlanning::RuleKinds::BudgetBasis.rule_name))
    @strictness = funding.strictness
    @funded = funding.positions.index_by { it.position.id }
    @budget_lines = funding.map.budget_lines.index_by(&:id)
    @by_line = funding.by_line
    split(cost.scenario.lines)
    lines = funding.map.budget_lines.sort_by(&:id).map { line(it, @by_line.fetch(it.id, [])) }
    forecast = cost.forecast.total
    Report.new(basis: @inclusive ? "inclusive" : "base_only", strictness: @strictness, period: @period, pay_view: cost.pay_view, reference_currency: @reference,
               lines:, cost_centres: cost_centres(lines, funding, cost.forecast), units: units(funding, cost.forecast),
               totals: totals(lines, funding, forecast),
               forecast:, unpriced: unpriced(cost.scenario.lines))
  end

  private

  # Each priced seat's money, split into what each held draw funds and what
  # is left unfunded, by line, unit and the seat's cost centre.
  def split(seats)
    @drawn = Hash.new { |hash, key| hash[key] = Hash.new(0r) }
    @drawn_by_unit = Hash.new { |hash, key| hash[key] = Hash.new(0r) }
    @unfunded_by_unit = Hash.new { |hash, key| hash[key] = Hash.new(0r) }
    @unfunded_by_cost_centre = Hash.new { |hash, key| hash[key] = Hash.new(0r) }
    seats.select { priced?(it) }.each do |seat|
      money = @inclusive ? seat.amount : seat.base
      funded = @funded[seat.position_id] if seat.position_id
      draws = funded ? funded.draws.select(&:held) : []
      drawn = draws.sum(0r) do |draw|
        part = money * draw.share * covered(@budget_lines[draw.budget_line_id], seat)
        @drawn[draw.budget_line_id][seat.currency] += part
        @drawn_by_unit[seat.unit_id][seat.currency] += part
        part
      end
      left = money - drawn
      next if left.zero?

      @unfunded_by_unit[seat.unit_id][seat.currency] += left
      @unfunded_by_cost_centre[seat.cost_centre][seat.currency] += left
    end
  end

  # The share of a seat's held days a line's period covers, so a line approved
  # for January funds none of what February and March cost.
  def covered(budget_line, seat)
    return 0r unless budget_line && seat.days.positive?

    first = [ budget_line.starts_on, seat.held.begin ].max
    last = [ budget_line.ends_on, seat.held.end ].min
    last >= first ? Rational((last - first).to_i + 1, seat.days) : 0r
  end

  def line(budget_line, draws)
    amount = budget_line.revealed_amount
    approved = amount && Rational(amount.to_s) * PayBand::PER_YEAR.fetch(budget_line.period) * Rational(overlap(budget_line), TeamPlanning::Cost::YEAR_DAYS)
    funded = @drawn[budget_line.id].sort.to_h
    heads = heads_of(draws)
    head_count = budget_line.head_count && Rational(budget_line.head_count.to_s)
    line = Line.new(line: budget_line, approved:, funded:, funded_heads: heads,
                    remaining: approved && approved - funded.fetch(budget_line.currency, 0r),
                    remaining_head_count: head_count && head_count - heads.fte,
                    mismatched: approved ? funded.keys - [ budget_line.currency ] : [], over: nil)
    line.with(over: over([ line ], "line"))
  end

  # Judged from the lines' own remaining, so it agrees with what the read shows.
  def over(lines, scope)
    return unless @strictness.fetch("scope") == scope

    strictness = TeamPlanning::RuleKinds::BudgetStrictness
    counted = lines.select(&:remaining_head_count)
    remaining = lines.select(&:remaining).group_by { it.line.currency }.transform_values { it.sum(0r, &:remaining) }
    Over.new(money: (remaining.select { |_, left| left.negative? }.keys.sort if strictness.money?(@strictness)),
             heads: (counted.sum(0r, &:remaining_head_count).negative? if strictness.heads?(@strictness) && counted.any?),
             mismatched: lines.flat_map(&:mismatched).uniq.sort)
  end

  def heads_of(draws) = Heads.new(positions: draws.map { it.first.position.id }.uniq.size, fte: draws.sum(0r) { |funded, draw| funded.fte * draw.share })

  def overlap(budget_line)
    first = [ budget_line.starts_on, @period.begin ].max
    last = [ budget_line.ends_on, @period.end ].min
    last >= first ? (last - first).to_i + 1 : 0
  end

  def cost_centres(lines, funding, forecast)
    by_line = lines.group_by { it.line.cost_centre.presence }
    unfunded = with_forecast(@unfunded_by_cost_centre, forecast.cost_centres)
    unfunded_heads = unfunded_heads_by(funding) { it.cost_centre.cost_centre }
    keys = (by_line.keys | unfunded.keys | unfunded_heads.keys).sort_by { [ it.nil? ? 1 : 0, it.to_s ] }
    keys.index_with do |cost_centre|
      lines = by_line.fetch(cost_centre, [])
      drawn = lines.flat_map { @by_line.fetch(it.line.id, []) }
      summed(lines, heads_of(drawn), unfunded.fetch(cost_centre, {}), unfunded_heads.fetch(cost_centre, NO_HEADS), scope: "cost_centre")
    end
  end

  def with_forecast(unfunded, forecast)
    (unfunded.keys | forecast.keys).to_h { [ it, add(unfunded.fetch(it, {}), forecast[it]&.native.to_h) ] }
  end

  def units(funding, forecast)
    live = funding.map.units.to_set(&:id)
    unit_of = ->(funded) { funded.position.unit_id if live.include?(funded.position.unit_id) }
    funded_heads = Hash.new(NO_HEADS)
    funding.positions.each { funded_heads[unit_of.(it)] += Heads.new(positions: it.funded? ? 1 : 0, fte: it.funded_fte) }
    unfunded_heads = unfunded_heads_by(funding, &unit_of)
    unfunded = with_forecast(@unfunded_by_unit, forecast.units)
    keys = (funded_heads.keys | unfunded_heads.keys | @drawn_by_unit.keys | unfunded.keys).sort_by { [ it.nil? ? 1 : 0, it.to_s ] }
    keys.index_with do |unit_id|
      UnitTotals.new(funded: converted(@drawn_by_unit.fetch(unit_id, {})), funded_heads: funded_heads[unit_id],
                     unfunded: converted(unfunded.fetch(unit_id, {})), unfunded_heads: unfunded_heads.fetch(unit_id, NO_HEADS))
    end
  end

  def unfunded_heads_by(funding, &key)
    funding.positions.reject(&:funded?).group_by(&key).transform_values do |positions|
      Heads.new(positions: positions.size, fte: positions.sum(0r) { it.fte - it.funded_fte })
    end
  end

  def totals(lines, funding, forecast)
    unfunded = @unfunded_by_cost_centre.values.reduce(forecast.native) { |sum, money| add(sum, money) }
    summed(lines, Heads.new(positions: funding.funded.positions, fte: funding.funded.fte), unfunded,
           Heads.new(positions: funding.unfunded.positions, fte: funding.unfunded.fte), scope: "organisation")
  end

  def summed(lines, funded_heads, unfunded, unfunded_heads, scope:)
    priced = lines.select(&:approved)
    counted = lines.select { it.line.head_count }
    head_count = counted.sum(0r) { Rational(it.line.head_count.to_s) } if counted.any?
    Totals.new(approved: converted(priced.group_by { it.line.currency }.transform_values { it.sum(0r, &:approved) }),
               head_count:, funded: converted(lines.map(&:funded).reduce({}) { |sum, money| add(sum, money) }), funded_heads:,
               remaining: converted(priced.group_by { it.line.currency }.transform_values { it.sum(0r, &:remaining) }),
               remaining_head_count: head_count && counted.sum(0r, &:remaining_head_count),
               unfunded: converted(unfunded), unfunded_heads:, over: over(lines, scope))
  end

  def unpriced(seats)
    seats.select { it.position_id && !priced?(it) }.group_by(&:position_id).sort.map do |position_id, group|
      draws = @funded[position_id]&.draws.to_a.select(&:held)
      Unpriced.new(position_id:, unit_id: group.first.unit_id, reasons: group.map(&:reason).uniq.sort, budget_line_ids: draws.map(&:budget_line_id))
    end
  end

  # A refused on-cost leaves the base priced, so base_only still counts it.
  def priced?(seat) = !seat.unpriced? || (!@inclusive && !seat.base.nil?)

  def add(one, other) = one.merge(other) { |_, a, b| a + b }

  def converted(native)
    native = native.reject { |_, amount| amount.zero? }.sort.to_h
    return TeamPlanning::Cost::Sum.new(native:, converted: nil, missing: [ TeamPlanning::Cost::NO_REFERENCE ]) unless @reference

    factors = native.keys.index_with { factor(it) }
    missing = factors.values.grep(String)
    return TeamPlanning::Cost::Sum.new(native:, converted: nil, missing:) if missing.any?

    TeamPlanning::Cost::Sum.new(native:, converted: native.sum(0r) { |currency, amount| amount * factors[currency] }, missing: [])
  end

  def factor(currency)
    @factors[currency] ||= ExchangeRate.factor(from: currency, to: @reference, on: @period.begin)
  rescue ExchangeRate::MissingRate => e
    @factors[currency] = e.message
  end
end
