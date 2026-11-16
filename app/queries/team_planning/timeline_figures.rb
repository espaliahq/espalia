# frozen_string_literal: true

# The quiet figures under each column of the timeline
# ([#452](https://github.com/espaliahq/espalia/issues/452)): what each step
# costs, what of it is unfunded against the budget, and what it can deliver.
# Each figure is the one the step's own cost, budget and capacity reads give,
# never worked out again here, so the timeline can't disagree with the tabs.
#
# Each step is resolved once, and its {TeamPlanning::Resolution::Shared}
# passed to every read of it, which keep their own rules for the viewer:
# midpoints and no budget money without the see-pay right. Today has no
# period, so it shows its yearly run rate and no budget. A step with no end
# date runs over the months its period shows, as each read does.
#
# @example
#   TeamPlanning::TimelineFigures.new(context:, plan:, scenario_id: q2).call.steps.last.cost
class TeamPlanning::TimelineFigures
  # @!attribute scenario_id [String]
  # @!attribute basis [String] "run_rate" for Today, "period" for a step
  # @!attribute period [Range<Date>]
  # @!attribute open_ended [Boolean]
  # @!attribute horizon_months [Integer, nil]
  # @!attribute cost [TeamPlanning::Cost::Sum] the step's own seats and its forecast; Today's run rate
  # @!attribute unpriced [Integer] the seats no band prices, left out of cost
  # @!attribute budget [TeamPlanning::Budget::Totals, nil] nil for Today; money nil without the see-pay right
  # @!attribute capacity [Hash{String => Rational}] model => the step's own capacity and its forecast
  Step = Data.define(:scenario_id, :basis, :period, :open_ended, :horizon_months, :cost, :unpriced, :budget, :capacity)

  # @!attribute pay_view [String] the cost read's
  # @!attribute money [Boolean] whether the viewer may see budget money
  # @!attribute reference_currency [String, nil]
  # @!attribute steps [Array<Step>] in the timeline's order, Today first
  Result = Data.define(:pay_view, :money, :reference_currency, :steps)

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String] the last step, as {TeamPlanning::Timeline} takes it
  # @param repository [TeamPlanning::Repository]
  def initialize(context:, plan:, scenario_id:, repository: TeamPlanning::Repository.new)
    @context = context
    @plan = plan
    @scenario_id = scenario_id
    @repository = repository
  end

  # @return [Result]
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def call
    TeamPlanning::Resolution.reusing do
      aggregate = @repository.load_plan(@plan.id)
      base = TeamPlanning::Baseline.new(context: @context, plan: @plan).structure
      reads = { cost: {}, capacity: {} }
      steps = aggregate.timeline_path(@scenario_id).map { step(aggregate, base, it, reads) }
      Result.new(pay_view: @pay_view, money: TeamPlanning::Budget.money_shown?(context: @context, plan: @plan),
                 reference_currency: @reference, steps:)
    end
  end

  private

  def step(aggregate, base, scenario_id, reads)
    shared, = TeamPlanning::Resolution.new(context: @context, plan: @plan, scenario_id:, repository: @repository, base:).shared(aggregate)
    on = { context: @context, plan: @plan, scenario_id:, repository: @repository, aggregate:, shared: }
    cost = TeamPlanning::Cost.new(**on, steps: reads[:cost]).call(at_end: false, baseline: false)
    @pay_view, @reference = cost.pay_view, cost.reference_currency
    today = cost.run_rate?
    Step.new(scenario_id:, basis: cost.basis, period: cost.period, open_ended: cost.open_ended, horizon_months: cost.horizon_months,
             cost: today ? cost.scenario.total : TeamPlanning::Cost.plus(cost.scenario.total, cost.forecast.total),
             unpriced: cost.scenario.unpriced.uniq(&:seat_id).size,
             budget: (TeamPlanning::Budget.new(**on, cost:).call.totals unless today),
             capacity: TeamPlanning::Capacity.split(**on, steps: reads[:capacity], baseline: false).total)
  end
end
