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
# Framework roles and levels and HRIS title mappings stay live: they say who
# is at which level, not what a level costs. The Org Graph is read as known
# on the archive day ({TeamPlanning::Baseline#known_on}).
#
# @example
#   inputs = TeamPlanning::PricingInputs.for(plan)
#   inputs.priced_on # => nil while the plan is live
class TeamPlanning::PricingInputs
  # The models a copy holds, by the key each is held under. A migration that
  # renames or drops a column of one must read old copies in {#rows}.
  MODELS = { pay_bands: PayBand, exchange_rates: ExchangeRate, budget_lines: BudgetLine,
             reference_currencies: ReferenceCurrency, planning_rule_defaults: PlanningRuleDefault }.freeze
  # What no copy keeps of a row: whose it is and who last edited it.
  LEFT_OUT = %w[tenant_id updated_by_person_id].freeze

  # @param tenant [Tenant]
  # @return [Hash{String => Object}] every row of each model, without who
  #   edited it, as JSON values
  def self.capture(tenant)
    TenantPlanningInputs::Projections::Tables.unless_rebuilding do
      rows = MODELS.to_h { |name, model| [ name.to_s, model.where(tenant_id: tenant.id).order(:id).map { it.attributes.except(*LEFT_OUT).as_json } ] }
      rows.merge("pay_bands_changed_at" => Tenant.where(id: tenant.id).pick(:pay_bands_changed_at).as_json)
    end
  end

  # @param plan [TeamPlanningPlan]
  # @param repository [TeamPlanning::Repository]
  # @return [TeamPlanning::PricingInputs]
  def self.for(plan, repository: TeamPlanning::Repository.new)
    CurrentPlanReads.fetch([ :pricing_inputs, plan.id, plan.archived_on ]) do
      frozen = plan.archived_on && repository.prices_frozen(plan.id)
      next new(plan) unless frozen

      CurrentPlanReads.frozen_inputs_for(frozen) { new(plan, priced_on: plan.archived_on, copy: frozen) }
    end
  end

  # @return [Date, nil] the archive day an archived plan is priced as on
  attr_reader :priced_on

  # @param plan [TeamPlanningPlan]
  # @param priced_on [Date, nil]
  # @param copy [Hash, nil] as {.capture} gave it
  def initialize(plan, priced_on: nil, copy: nil)
    @plan = plan
    @priced_on = priced_on
    @copy = copy
  end

  # @return [Array<PayBand>] read only, in list order, as the last match wins
  def bands = @bands ||= rows(:pay_bands).sort_by { [ it.position, it.id ] }.freeze

  # @return [Time, nil] when a band last changed, as the tenant recorded it
  def bands_changed_at
    recorded = @copy ? @copy["pay_bands_changed_at"]&.then { Time.zone.parse(it) } : @plan.tenant.pay_bands_changed_at
    [ recorded, *bands.map(&:updated_at) ].compact.max
  end

  # @return [String, nil]
  def reference_currency
    return @reference_currency if defined?(@reference_currency)

    @reference_currency = rows(:reference_currencies).first&.currency
  end

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
  def budget_lines = @budget_lines ||= rows(:budget_lines).sort_by { [ it.starts_on, it.id ] }.freeze

  # @return [Hash{String => Hash}] each rule's value, the tenant's own over the built-in default
  def rule_defaults = @rule_defaults ||= PlanningRuleDefault.values_over_defaults(rows(:planning_rule_defaults)).freeze

  private

  def rows(name)
    model = MODELS.fetch(name)
    return model.where(tenant_id: @plan.tenant_id).to_a unless @copy

    blank = model.column_defaults.merge("tenant_id" => @plan.tenant_id)
    @copy.fetch(name.to_s, []).map { model.instantiate(blank.merge(it.slice(*model.column_names))).tap(&:readonly!) }
  end
end
