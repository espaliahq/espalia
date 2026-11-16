# frozen_string_literal: true

# Which budget lines each position in a scenario draws on
# ([#345](https://github.com/espaliahq/espalia/issues/345)).
#
# A position draws on the most specific line that matches it: the line's
# cost centre is the position's ({TeamPlanning::PositionCostCentres}), its
# period overlaps the days the position is held, and each of role, level and
# location the line states is the position's. A line with no cost centre
# matches any position and is the least specific; past that, a line is more
# specific the more of role, level and location it states. Two lines that
# match equally well leave the position ambiguous, and none leaves it
# unmatched. Both are unfunded, and nothing is picked silently.
#
# The {TeamPlanning::RuleKinds::BudgetStrictness} rule names the dimensions
# that must match ([#384](https://github.com/espaliahq/espalia/issues/384)).
# A dimension outside it no longer blocks a line, and a line whose stated
# dimensions agree outranks one where they differ. Each draw lists where its
# line differs from the position: a variance on a dimension the rule holds,
# else a record of the trade. Its default holds every dimension, which is how
# lines have always matched.
#
# A {TeamPlanning::Events::PositionFundingSet} wins over the derived line. A
# draw on a line the scenario no longer holds funds nothing.
#
# Each line lists its positions in draw order: filled positions first, then
# open ones replacing a leaver, as that budget is already committed, then
# other open ones, each group by the day it is first held, then by id.
#
# Positions are the resolved map's, the same ones {TeamPlanning::Cost} reads,
# each at its whole FTE, so funded and unfunded always add up to its
# positions and their FTE.
#
# @example
#   TeamPlanning::Funding.new(context:, plan:, scenario_id:).call.totals
class TeamPlanning::Funding
  DRAW_ORDER = %w[filled backfill open].freeze
  # Each {TeamPlanning::RuleKinds::BudgetStrictness::DIMENSIONS} entry: what a
  # line states, and what it compares with on the position.
  MATCHED = {
    "role" => [ :role_id, ->(funded) { funded.position.role_id } ],
    "level" => [ :level_id, ->(funded) { funded.position.level_id } ],
    "cost_centre" => [ :cost_centre, ->(funded) { funded.cost_centre.cost_centre } ],
    "location" => [ :location, ->(funded) { funded.location } ]
  }.freeze

  # Why a position, or part of one, is unfunded.
  REASONS = {
    "no_line" => "No budget line matches the position",
    "ambiguous" => "Two or more budget lines match the position equally well",
    "line_gone" => "Its funding names a budget line this scenario no longer holds"
  }.freeze

  # @!attribute budget_line_id [String]
  # @!attribute share [Rational] the part of the position it funds
  # @!attribute held [Boolean] false when the scenario no longer holds the line
  # @!attribute differs_on [Array<String>] the dimensions the line states that the position doesn't share
  # @!attribute variance [Array<String>] those of them the strictness rule holds
  Draw = Data.define(:budget_line_id, :share, :held, :differs_on, :variance)

  # One position's funding.
  #
  # @!attribute position [TeamPlanning::Baseline::Position]
  # @!attribute fte [Rational]
  # @!attribute cost_centre [TeamPlanning::PositionCostCentres::Resolved]
  # @!attribute location [String, nil] the country it matched on: an occupant's, else a leaver's it replaces
  # @!attribute draw_reason [String] a {DRAW_ORDER} entry, why it draws where it does in each line
  # @!attribute starts_on [Date] the first day it is held in the period
  # @!attribute source [String] "set" by a PositionFundingSet, or "derived"
  # @!attribute draws [Array<Draw>]
  # @!attribute matching_ids [Array<String>] for a derived position, the lines that tied for most specific
  # @!attribute reason [String, nil] a {REASONS} key when any of it is unfunded
  Funded = Data.define(:position, :fte, :cost_centre, :location, :draw_reason, :starts_on, :source, :draws, :matching_ids, :reason) do
    # @return [Rational] the part of the position its held draws fund
    def funded_share = draws.select(&:held).sum(0r, &:share)

    # @return [Boolean] the whole position is funded
    def funded? = funded_share == 1

    # @return [Rational]
    def funded_fte = fte * funded_share

    # @return [Array] its place in a line's draw order
    def order = [ DRAW_ORDER.index(draw_reason), starts_on, position.id ]
  end

  # @!attribute positions [Integer]
  # @!attribute fte [Rational]
  Count = Data.define(:positions, :fte)

  # @!attribute period [Range<Date>]
  # @!attribute map [TeamPlanning::Baseline::Map]
  # @!attribute strictness [Hash] the {TeamPlanning::RuleKinds::BudgetStrictness} value it matched under
  # @!attribute positions [Array<Funded>] by position id
  Report = Data.define(:period, :map, :strictness, :positions) do
    # @return [Count] every position
    def total = Count.new(positions: positions.size, fte: positions.sum(0r, &:fte))

    # @return [Count] the positions funded whole, and the FTE every draw funds
    def funded = Count.new(positions: positions.count(&:funded?), fte: positions.sum(0r, &:funded_fte))

    # @return [Count] the rest, so funded and unfunded always add up to {#total}
    def unfunded = Count.new(positions: total.positions - funded.positions, fte: total.fte - funded.fte)

    # @return [Hash{String => Array<Array(Funded, Draw)>}] line id => each position drawing on it, in draw order
    def by_line
      positions.flat_map { |funded| funded.draws.select(&:held).map { [ funded, it ] } }
        .group_by { it.last.budget_line_id }.transform_values { it.sort_by { |funded, _| funded.order } }
    end
  end

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String] a scenario, never the root, which has no period
  # @param repository [TeamPlanning::Repository]
  # @param aggregate [TeamPlanning::PlanAggregate, nil] the plan, already loaded
  def initialize(context:, plan:, scenario_id:, repository: TeamPlanning::Repository.new, aggregate: nil)
    @context = context
    @plan = plan
    @scenario_id = scenario_id
    @repository = repository
    @aggregate = aggregate
  end

  # @return [Report]
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for the root, or a scenario the plan doesn't have
  def call
    aggregate = @aggregate || @repository.load_plan(@plan.id)
    raise TeamPlanning::Error, "No such scenario" unless aggregate.scenario?(@scenario_id)
    raise TeamPlanning::Error, "The baseline has no period to fund, so read one of the plan's scenarios" if @scenario_id == @plan.id

    @period = aggregate.period_of(@scenario_id)
    @map = TeamPlanning::Resolution.new(context: @context, plan: @plan, scenario_id: @scenario_id, repository: @repository).structure(aggregate)
    @cost_centres = TeamPlanning::PositionCostCentres.new(@map, tenant_id: @plan.tenant_id)
    @lines = @map.budget_lines.index_by(&:id)
    @strictness = @map.rule(TeamPlanning::RuleKinds::BudgetStrictness.rule_name)
    @held = @strictness.fetch("match")
    Report.new(period: @period, map: @map, strictness: @strictness, positions: @map.positions.sort_by(&:id).map { fund(it) })
  end

  private

  def fund(position)
    funded = Funded.new(position:, fte: Rational(position.fte.to_s), cost_centre: @cost_centres.of(position), location: location_of(position),
                        draw_reason: draw_reason(position), starts_on: starts_on(position), source: "derived", draws: [], matching_ids: [], reason: nil)
    set = @map.fundings[position.id]
    set ? funded_as_set(funded, set) : derived(funded)
  end

  def funded_as_set(funded, set)
    draws = set.map do
      line = @lines[it[:budget_line_id]]
      draw(line, line ? differs_on(line, funded) : [], budget_line_id: it[:budget_line_id], share: Rational(it[:share]))
    end
    funded.with(source: "set", draws:, reason: ("line_gone" unless draws.all?(&:held)))
  end

  def derived(funded)
    matching = @lines.values.filter_map do |line|
      differs = differs_on(line, funded)
      [ line, differs ] if line.starts_on <= @period.end && line.ends_on >= funded.starts_on && (differs & @held).empty?
    end
    best = matching.group_by { |line, differs| specificity(line, differs) }.max_by(&:first)&.last.to_a.sort_by { it.first.id }
    return funded.with(reason: "no_line") if best.empty?
    return funded.with(matching_ids: best.map { it.first.id }, reason: "ambiguous") if best.many?

    line, differs = best.first
    funded.with(draws: [ draw(line, differs, budget_line_id: line.id, share: 1r) ], matching_ids: [ line.id ])
  end

  def draw(line, differs_on, budget_line_id:, share:)
    Draw.new(budget_line_id:, share:, held: !line.nil?, differs_on:, variance: differs_on & @held)
  end

  # A line with no cost centre ranks below one that agrees on it; past that,
  # the more dimensions agree the better, and the fewer differ.
  def specificity(line, differs)
    agrees = ->(dimension) { stated(line, dimension) && differs.exclude?(dimension) }
    [ agrees.("cost_centre") ? 1 : 0, %w[role level location].count(&agrees), -differs.size ]
  end

  # @return [Array<String>] the dimensions the line states that the position doesn't share
  def differs_on(line, funded)
    MATCHED.filter_map do |dimension, (field, of_position)|
      dimension if stated(line, dimension) && key(dimension, line.public_send(field)) != key(dimension, of_position.(funded))
    end
  end

  def stated(line, dimension) = line.public_send(MATCHED.fetch(dimension).first).present?

  def key(dimension, value) = dimension == "location" ? PayBand.location_key(value) : value

  def occupants = @occupants ||= @map.occupants

  def backfills = @backfills ||= @map.backfills

  def people = @people ||= @map.people.index_by(&:id)

  def departed_countries = @departed_countries ||= @map.departed.to_h { [ it.person_id, it.country ] }

  def draw_reason(position)
    return "filled" if occupants.key?(position.id)

    position.basis == "backfill" || backfills.key?(position.id) ? "backfill" : "open"
  end

  # The first day any part of it is held, as {TeamPlanning::Cost} opens it:
  # each leaver it replaces opens their FTE the day after they go, or all
  # step without a date, and FTE no leaver here opens is held all step.
  def starts_on(position)
    return @period.begin if occupants.key?(position.id)

    open = Rational(position.fte.to_s)
    leavers = @map.people.select { it.leaving? && it.backfill_id == position.id }
                  .map { [ fte_of(it), TeamPlanning::Events::DepartureSet.leaving_date(it.departure[:leaves_on]) ] }
    starts = leavers.sort_by { |_, last| last || Date.new(0) }.filter_map do |fte, last|
      fte = [ fte, open ].min
      next unless fte.positive?

      open -= fte
      last ? last + 1 : @period.begin
    end
    starts << @period.begin if open.positive?
    starts.min.clamp(@period.begin, @period.end)
  end

  def fte_of(member)
    fte = member.planned_or_own(:fte)
    fte == TeamPlanning::Baseline::UNKNOWN || fte.nil? ? 1r : Rational(fte.to_s)
  end

  def location_of(position)
    held = occupants.fetch(position.id, []).sort_by { |person, place| [ -place.allocation.to_f, person.id ] }.map(&:first)
    replaced = backfills.fetch(position.id, []).map { people[it]&.country || departed_countries[it] }
    (held.map(&:country) + replaced).find(&:present?)
  end
end
