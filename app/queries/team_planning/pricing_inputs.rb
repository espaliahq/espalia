# frozen_string_literal: true

# What a plan is priced with beyond its own changes: the tenant's pay bands,
# reference currency, exchange rates, budget lines and planning rule
# defaults. Every read that prices a plan takes these from here and never
# from the tables, so an archived plan can hold still.
#
# A live plan reads the tables as they are now. An archived plan reads the
# copy its {TeamPlanning::Events::PlanPricesFrozen} sealed under the plan's
# key. A plan archived before the copy existed has none, and reads live.
#
# Framework roles and levels, HRIS title mappings and the Org Graph stay
# live: they say who is at which level, not what a level costs.
#
# @example
#   inputs = TeamPlanning::PricingInputs.for(plan)
#   inputs.frozen_on # => nil while the plan is live
class TeamPlanning::PricingInputs
  # The models a copy holds, each with the attributes it leaves out.
  MODELS = { pay_bands: PayBand, exchange_rates: ExchangeRate, budget_lines: BudgetLine,
             reference_currencies: ReferenceCurrency, planning_rule_defaults: PlanningRuleDefault }.freeze
  LEFT_OUT = %w[tenant_id updated_by_id].freeze

  # @param tenant [Tenant]
  # @return [Hash{String => Object}] every row of each model, without who
  #   edited it, as JSON values
  def self.capture(tenant)
    rows = MODELS.to_h { |name, model| [ name.to_s, model.where(tenant_id: tenant.id).order(:id).map { it.attributes.except(*LEFT_OUT).as_json } ] }
    rows.merge("pay_bands_changed_at" => tenant.pay_bands_changed_at.as_json)
  end

  # @param plan [TeamPlanningPlan]
  # @param repository [TeamPlanning::Repository]
  # @return [TeamPlanning::PricingInputs]
  def self.for(plan, repository: TeamPlanning::Repository.new)
    CurrentPlanReads.fetch([ :pricing_inputs, plan.id, plan.archived_on ]) do
      frozen = plan.archived_on && repository.prices_frozen(plan.id)
      frozen ? new(plan, frozen_on: plan.archived_on, copy: frozen) : new(plan)
    end
  end

  # @return [Date, nil] the archive day an archived plan is priced as on
  attr_reader :frozen_on

  # @param plan [TeamPlanningPlan]
  # @param frozen_on [Date, nil]
  # @param copy [Hash, nil] as {.capture} gave it
  def initialize(plan, frozen_on: nil, copy: nil)
    @plan = plan
    @frozen_on = frozen_on
    @copy = copy
  end

  # @return [Array<PayBand>] read only
  def bands = @bands ||= rows(:pay_bands)

  # @return [Time, nil] when a band last changed, as the tenant recorded it
  def bands_changed_at
    recorded = @copy ? @copy["pay_bands_changed_at"]&.then { Time.zone.parse(it) } : @plan.tenant.pay_bands_changed_at
    [ recorded, *bands.map(&:updated_at) ].compact.max
  end

  # @return [String, nil]
  def reference_currency = rows(:reference_currencies).first&.currency

  # @param from [String]
  # @param to [String]
  # @param on [Date]
  # @return [Rational]
  # @raise [ExchangeRate::MissingRate]
  def factor(from:, to:, on:)
    return ExchangeRate.factor(from:, to:, on:) unless @copy

    ExchangeRate.factor(from:, to:, on:, rates: @rates ||= rows(:exchange_rates))
  end

  # @return [Array<::BudgetLine>] read only, by start
  def budget_lines = @budget_lines ||= rows(:budget_lines).sort_by { [ it.starts_on, it.id ] }

  # @return [Hash{String => Hash}] each rule's value, the tenant's own over the built-in default
  def rule_defaults
    return PlanningRuleDefault.values_for(@plan.tenant_id) unless @copy

    defaults = TeamPlanning::RuleKinds.defaults
    defaults.merge(rows(:planning_rule_defaults).select { defaults.key?(it.rule) }.to_h { [ it.rule, it.value ] })
  end

  private

  def rows(name)
    model = MODELS.fetch(name)
    return model.where(tenant_id: @plan.tenant_id).to_a unless @copy

    @copy.fetch(name.to_s, []).map { model.new(it.slice(*model.column_names)).tap(&:readonly!) }
  end
end
