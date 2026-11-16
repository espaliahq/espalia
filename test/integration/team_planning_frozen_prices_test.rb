# frozen_string_literal: true

require "test_helper"

# An archived plan is priced with the tenant's inputs as they stood on its
# archive day, whatever changes after, until it is restored.
class TeamPlanningFrozenPricesTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2025-12-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  READS = %w[Cost ScenarioCosts Capacity Budget Funding Forecast BudgetLines].freeze
  # What each archive's copy holds, frozen into every PlanPricesFrozen already stored.
  COPIED = { pay_bands: %w[id level_id role_name level_name location location_key currency period minimum midpoint maximum
                           role_family_id role_id level_ordinal position created_at updated_at],
             exchange_rates: %w[id from_currency to_currency rate applies_from created_at updated_at],
             budget_lines: %w[id starts_on ends_on amount currency period head_count role_id level_id role_name level_name location
                              cost_centre origin approved_on created_at updated_at],
             reference_currencies: %w[id currency created_at updated_at],
             planning_rule_defaults: %w[id rule value created_at updated_at] }.freeze
  # What a frozen read may still take live: the plan itself, who may see it,
  # and who is at which level where. Prices come from the archive's copy.
  STRUCTURE = %w[event_store_events event_store_events_in_streams plan_encryption_keys team_planning_plans team_planning_plan_members
                 tenants people org_fact_periods org_leavers framework_roles framework_levels hris_role_mappings person_framework_assignments].to_set.freeze

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    departments = SecureRandom.uuid_v7
    @engineering = SecureRandom.uuid_v7

    travel_to Time.utc(2025, 12, 15, 9)
    as_tenant do
      @engineer = create(:framework_role, code: "E", name: "Software Engineer")
      @e5 = create(:framework_level, role_id: @engineer.role_id, ordinal: 5, title: "Senior SWE")
      @e6 = create(:framework_level, role_id: @engineer.role_id, ordinal: 6, title: "Staff SWE")

      structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: "2025-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: departments, effective_on: "2025-01-01")

      @ada, @brook = %w[Ada Brook].map { create(:person, tenant: @tenant, name: "#{it} Quill") }
      [ @ada, @brook ].each do |person|
        people.record_person(person.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0,
                                                   country: "Mu", cost_centre: "Platform")
        people.set_membership(person.id, @engineering, **ESPALIA, allocation: 1.0)
      end

      ReferenceCurrency.create!(currency: "EUR")
      PayBand.new(currency: "EUR", period: "year", minimum: 0, midpoint: 60_000, maximum: 70_000).tap { it.match_on(role: @engineer) }.save!
      @band = PayBand.create!(level: @e5, currency: "EUR", period: "year", minimum: 0, midpoint: 100_000, maximum: 200_000)
      PayBand.create!(level: @e6, currency: "USD", period: "hour", minimum: 0, midpoint: 75, maximum: 150)
      @rate = ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", rate: "0.9", applies_from: "2025-01-01")
      @line = BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 500_000, currency: "EUR",
                                 period: "year", cost_centre: "Platform", head_count: 4)
      rule("on_cost", { model: "flat", params: { percent: "10" } })
      rule("capacity_model", { families: {}, roles: { @engineer.role_id => { model: "per_fte" } } })
      rule("attrition", { yearly_rate: "0.2" })
      rule("time_to_hire", { days: "30" })

      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      TeamPlanning::CommandHandler.new(actor: context_for(@planner)).create_plan(@plan_id, name: "Next year", base_on: Date.new(2026, 1, 1))
    end
    @year = operation(Operations::TeamPlanning::ForkScenario, scenario_id: nil, relation: "then", name: "2026", ends_on: "2026-12-31")[:scenario_id]
    [ @e5, @e6 ].each do |level|
      operation(Operations::TeamPlanning::SetPosition, role_id: @engineer.role_id, level_id: level.level_id, unit_id: @engineering, fte: 1,
                                                       basis: "new", cost_centre: "Platform")
    end
    operation(Operations::TeamPlanning::ArchivePlan, scenario_id: nil)
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def context_for(tenant_user) = AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)

  def operation(operation, scenario_id: @year, **params)
    as_tenant { operation.call(context: context_for(@planner), params: { plan_id: @plan_id, scenario_id:, **params }.compact) }
  end

  def rule(name, value) = PlanningRuleDefault.find_or_initialize_by(rule: name).update!(value: value.deep_stringify_keys)

  def reads
    READS.to_h do |name|
      scenario_id = name == "ScenarioCosts" ? nil : @year
      [ name, operation(Operations::TeamPlanning.const_get(name), scenario_id:).except(:archived_on, :note, :priced_on) ]
    end
  end

  def plan = as_tenant { TeamPlanningPlan.find(@plan_id) }

  def e5_midpoint = as_tenant { TeamPlanning::PricingInputs.for(plan).bands.find { it.id == @band.id }.midpoint }

  def changes
    { "a band's figures" => -> { @band.update!(midpoint: 120_000, maximum: 240_000) },
      "a new band" => -> { PayBand.create!(level: @e5, location: "Mu", currency: "EUR", period: "year", minimum: 0, midpoint: 90_000, maximum: 95_000) },
      "the reference currency" => -> { ReferenceCurrency.current.update!(currency: "USD") },
      "a rate" => -> { @rate.update!(rate: "0.5") },
      "a new rate" => -> { ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", rate: "2", applies_from: "2025-12-10") },
      "a budget line" => -> { @line.update!(amount: 10_000, cost_centre: "Other") },
      "a new budget line" => -> { BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", head_count: 9) },
      "the on-cost rule" => -> { rule("on_cost", { model: "flat", params: { percent: "50" } }) },
      "the capacity rule" => -> { rule("capacity_model", { families: {}, roles: {} }) },
      "the working hours rule" => -> { rule("working_hours", { hours_per_year: "1000" }) },
      "the attrition rule" => -> { rule("attrition", { yearly_rate: "0.9" }) },
      "the time to hire rule" => -> { rule("time_to_hire", { days: "200" }) },
      "the budget basis rule" => -> { rule("budget_basis", { basis: "base_only" }) },
      "the budget strictness rule" => -> { rule("budget_strictness", TeamPlanning::RuleKinds::BudgetStrictness::PRESETS.fetch("envelope")) },
      "a removed band" => -> { PayBand.find_by(level_id: @e6.level_id).destroy! },
      "the band order" => -> { PayBand.reorder!(PayBand.order(:position).pluck(:id).reverse) } }
  end

  should "give every pricing read the same figures after each input changes, until the plan is restored" do
    archived = reads
    travel_to Time.utc(2026, 2, 1, 9)

    changes.each do |input, change|
      as_tenant(&change)
      assert_equal archived, reads, "#{input} moved an archived plan's figures"
    end

    operation(Operations::TeamPlanning::RestorePlan, scenario_id: nil)
    today = reads
    READS.each { |name| assert_not_equal archived[name], today[name], "a restored plan's #{name} should use today's inputs" }
    assert_equal "USD", today["Cost"][:reference_currency]
  end

  should "move a live plan's figures with each of those changes, so each one tests the freeze" do
    operation(Operations::TeamPlanning::RestorePlan, scenario_id: nil)
    travel_to Time.utc(2026, 2, 1, 9)

    changes.each do |input, change|
      before = reads
      as_tenant(&change)
      assert_not_equal before, reads, "#{input} moves no live figure"
    end
  end

  should "read no table but the plan's own and the organisation's structure while frozen, so no new input bypasses the copy" do
    tables = Set.new
    watch = ->(*, payload) { tables.merge(payload[:sql].scan(/(?:FROM|JOIN)\s+"(\w+)"/i).flatten) }
    ActiveSupport::Notifications.subscribed(watch, "sql.active_record") { reads }

    assert_empty tables - STRUCTURE, "Route each input a pricing read takes through TeamPlanning::PricingInputs, " \
                                     "or add its table to STRUCTURE if it says who is where rather than what anything costs"
  end

  should "reveal the frozen copy once per read, however many scenarios and currencies it prices" do
    key_reads = 0
    watch = ->(*, payload) { key_reads += 1 if payload[:sql].include?("plan_encryption_keys") }
    ActiveSupport::Notifications.subscribed(watch, "sql.active_record") do
      operation(Operations::TeamPlanning::ScenarioCosts, scenario_id: nil)
      operation(Operations::TeamPlanning::Budget)
    end

    assert_equal 1, key_reads
  end

  should "rebuild a frozen band as copied, without asking today's Org Graph how to spell its country" do
    operation(Operations::TeamPlanning::RestorePlan, scenario_id: nil)
    as_tenant(&changes.fetch("a new band"))
    operation(Operations::TeamPlanning::ArchivePlan, scenario_id: nil)
    inputs = as_tenant { TeamPlanning::PricingInputs.for(plan) }

    queries = []
    watch = ->(*, payload) { queries << payload[:sql] }
    locations = ActiveSupport::Notifications.subscribed(watch, "sql.active_record") { as_tenant { inputs.bands.map(&:location) } }

    assert_includes locations, "Mu"
    assert_empty queries
  end

  should "build an archived plan's inputs once per request, even outside a reusing block" do
    assert_same as_tenant { TeamPlanning::PricingInputs.for(plan) }, as_tenant { TeamPlanning::PricingInputs.for(plan) }
  end

  should "keep nothing revealed from a plan's copy once the plan is deleted in the same request" do
    as_tenant { TeamPlanning::PricingInputs.for(plan).bands }
    operation(Operations::TeamPlanning::DeletePlan, scenario_id: nil)

    assert_nil as_tenant { TeamPlanning::Repository.new.prices_frozen(@plan_id) }
  end

  should "price an archived plan with today's inputs where no plan key can be read, rather than fail" do
    PlanKeyStore.stub(:available?, false) do
      assert_nil as_tenant { TeamPlanning::Repository.new.prices_frozen(@plan_id) }
      assert_match "still use today's", operation(Operations::TeamPlanning::Cost)[:note]
    end
  end

  should "give an archived plan's rule as its archive copied the tenant's default, and say so" do
    as_tenant(&changes.fetch("the attrition rule"))
    read = operation(Operations::TeamPlanning::Rule, rule: "attrition")

    assert_equal({ "yearly_rate" => "0.2" }, read[:value])
    assert_equal "2025-12-15", read[:priced_on]
  end

  should "copy the columns every stored copy holds, so a change to them meets the copies already stored" do
    TeamPlanning::PricingInputs::MODELS.each do |name, model|
      assert_equal COPIED.fetch(name).sort, (model.column_names - TeamPlanning::PricingInputs::LEFT_OUT).sort,
                   "#{model.table_name} changed: read the copies stored before it in TeamPlanning::PricingInputs#rows, then update COPIED"
    end
  end

  should "read a column a stored copy predates as its default, and the copied rows as the plan's tenant's" do
    copy = { "pay_bands" => [ { "id" => @band.id, "level_id" => @e5.level_id, "currency" => "EUR", "period" => "year",
                                "minimum" => "0", "midpoint" => "100000", "maximum" => "200000" } ] }
    band = TeamPlanning::PricingInputs.new(plan, priced_on: plan.archived_on, copy:).bands.sole

    assert_equal [ "", @tenant.id ], [ band.location, band.tenant_id ]
  end

  should "read a frozen copy only until the plan is restored, and take a fresh one when it is archived again" do
    as_tenant(&changes.fetch("a band's figures"))
    assert_equal 100_000, e5_midpoint

    operation(Operations::TeamPlanning::RestorePlan, scenario_id: nil)
    assert_nil as_tenant { TeamPlanning::Repository.new.prices_frozen(@plan_id) }, "the old copy is set aside on restore"
    assert_nil as_tenant { TeamPlanning::PricingInputs.for(plan).priced_on }

    operation(Operations::TeamPlanning::ArchivePlan, scenario_id: nil)
    as_tenant { @band.update!(midpoint: 130_000, maximum: 260_000) }
    assert_equal 120_000, e5_midpoint
  end
end
