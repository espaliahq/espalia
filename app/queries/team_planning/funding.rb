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
# A {TeamPlanning::Events::PositionFundingSet} wins over the derived line. A
# draw on a line the scenario no longer holds funds nothing.
#
# Each line lists its positions in draw order: filled positions first, then
# open ones replacing a leaver, as that budget is already committed, then
# other open ones, each group by the day it is first held, then by id.
#
# Positions are the resolved map's, the same ones {TeamPlanning::Cost} reads,
# so funded and unfunded always add up to the positions and FTE it prices.
#
# @example
#   TeamPlanning::Funding.new(context:, plan:, scenario_id:).call.totals
class TeamPlanning::Funding
  DRAW_ORDER = %w[filled backfill open].freeze

  # Why a position, or part of one, is unfunded.
  REASONS = {
    "no_line" => "No budget line matches the position",
    "ambiguous" => "Two or more budget lines match the position equally well",
    "line_gone" => "Its funding names a budget line this scenario no longer holds"
  }.freeze

  # @!attribute budget_line_id [String]
  # @!attribute share [Rational] the part of the position it funds
  # @!attribute held [Boolean] false when the scenario no longer holds the line
  Draw = Data.define(:budget_line_id, :share, :held)

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
  # @!attribute positions [Array<Funded>] by position id
  Report = Data.define(:period, :map, :positions) do
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
    raise TeamPlanning::Error, "No such scenario" unless aggregate.scenario?(@scenario_id)
    raise TeamPlanning::Error, "The baseline has no period to fund, so read one of the plan's scenarios" if @scenario_id == @plan.id

    @period = aggregate.period_of(@scenario_id)
    @map = TeamPlanning::Resolution.new(context: @context, plan: @plan, scenario_id: @scenario_id, repository: @repository).structure(aggregate)
    @cost_centres = TeamPlanning::PositionCostCentres.new(@map, tenant_id: @plan.tenant_id)
    @lines = @map.budget_lines.index_by(&:id)
    Report.new(period: @period, map: @map, positions: @map.positions.sort_by(&:id).map { fund(it) })
  end

  private

  def fund(position)
    funded = Funded.new(position:, fte: Rational(position.fte.to_s), cost_centre: @cost_centres.of(position), location: location_of(position),
                        draw_reason: draw_reason(position), starts_on: starts_on(position), source: "derived", draws: [], matching_ids: [], reason: nil)
    set = @map.fundings[position.id]
    set ? funded_as_set(funded, set) : derived(funded)
  end

  def funded_as_set(funded, set)
    draws = set.map { Draw.new(budget_line_id: it[:budget_line_id], share: Rational(it[:share]), held: @lines.key?(it[:budget_line_id])) }
    funded.with(source: "set", draws:, reason: ("line_gone" unless draws.all?(&:held)))
  end

  def derived(funded)
    matching = @lines.values.select { matches?(it, funded) }
    best = matching.group_by { specificity(it) }.max_by(&:first)&.last.to_a.sort_by(&:id)
    return funded.with(reason: "no_line") if best.empty?
    return funded.with(matching_ids: best.map(&:id), reason: "ambiguous") if best.many?

    funded.with(draws: [ Draw.new(budget_line_id: best.first.id, share: 1r, held: true) ], matching_ids: best.map(&:id))
  end

  def matches?(line, funded)
    position = funded.position
    (line.cost_centre.blank? || line.cost_centre == funded.cost_centre.cost_centre) &&
      line.starts_on <= @period.end && line.ends_on >= funded.starts_on &&
      (line.role_id.blank? || line.role_id == position.role_id) &&
      (line.level_id.blank? || line.level_id == position.level_id) &&
      (line.location.blank? || PayBand.location_key(line.location) == PayBand.location_key(funded.location))
  end

  def specificity(line) = [ line.cost_centre.present? ? 1 : 0, [ line.role_id, line.level_id, line.location ].count(&:present?) ]

  def occupants = @occupants ||= @map.occupants

  def backfills = @backfills ||= @map.backfills

  def people = @people ||= @map.people.index_by(&:id)

  def draw_reason(position)
    return "filled" if occupants.key?(position.id)

    position.basis == "backfill" || backfills.key?(position.id) ? "backfill" : "open"
  end

  # An occupied position is held all period. An open one replacing someone
  # still here is held from the day after the earliest of them leaves.
  def starts_on(position)
    return @period.begin if occupants.key?(position.id)

    dates = backfills.fetch(position.id, []).filter_map { people[it]&.departure&.dig(:leaves_on) }
                     .filter_map { TeamPlanning::Events::DepartureSet.leaving_date(it) }
    return @period.begin if dates.empty?

    (dates.min + 1).clamp(@period.begin, @period.end)
  end

  def location_of(position)
    held = occupants.fetch(position.id, []).sort_by { |person, place| [ -place.allocation.to_f, person.id ] }.map(&:first)
    replaced = backfills.fetch(position.id, []).filter_map { people[it] }
    (held + replaced).map(&:country).find(&:present?)
  end
end
