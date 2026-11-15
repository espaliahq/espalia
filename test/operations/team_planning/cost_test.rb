# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::CostTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2025-12-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    teams = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7

    travel_to Time.utc(2025, 12, 15, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @engineer = create(:framework_role, code: "E", name: "Software Engineer")
      @e5 = create(:framework_level, role_id: @engineer.role_id, ordinal: 5, title: "Senior SWE")
      structure.define_taxonomy([ { level_id: teams, name: "Team" } ], effective_on: "2025-01-01")
      structure.create_unit(@payments, "Payments", level_id: teams, effective_on: "2025-01-01")

      @ada, @cy = %w[Ada Cy].map { create(:person, tenant: @tenant, name: "#{it} Quill") }
      people.record_person(@ada.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0,
                                               cost_centre: "CC-1")
      people.record_person(@cy.id, **ESPALIA, employment_status: "employed", title: "Juggler", level: "5", fte: 1.0)
      people.set_membership(@ada.id, @payments, **ESPALIA, allocation: 1.0)
      people.set_membership(@cy.id, @payments, **ESPALIA, allocation: 1.0)

      PayBand.create!(level: @e5, currency: "EUR", period: "year", minimum: 0, midpoint: 100_000, maximum: 200_000)
      ReferenceCurrency.create!(currency: "EUR")

      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-01-01")[:plan_id]
    @year = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "2026", ends_on: "2026-12-31")[:scenario_id]
  end

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def cost(as: @admin, **params) = call(Operations::TeamPlanning::Cost, as:, plan_id: @plan_id, scenario_id: @year, **params)

  should "give totals, units and cost centres as decimal strings beside the baseline, without any seat's working" do
    position_id = call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @year, role_id: @engineer.role_id,
                                                               level_id: @e5.level_id, unit_id: @payments, fte: 0.5, basis: "new")[:position_id]
    result = cost

    assert_equal({ starts_on: "2026-01-01", ends_on: "2026-12-31" }, result[:period])
    assert_equal [ "EUR", "2025-12-15T09:00:00Z" ], result.values_at(:reference_currency, :bands_changed_at)
    assert_equal({ scenario: { native: { "EUR" => "150000" }, converted: "150000", missing: [] },
                   baseline: { native: { "EUR" => "100000" }, converted: "100000", missing: [] },
                   difference: { native: { "EUR" => "50000" }, converted: "50000", missing: [] } }, result[:total])

    payments = result[:units].find { it[:unit_id] == @payments }
    assert_equal [ "Payments", "150000", "150000" ], [ payments[:name], payments[:scenario][:converted], payments[:with_below][:scenario][:converted] ]
    assert_equal [ [ "CC-1", "100000" ], [ nil, "50000" ] ], result[:cost_centres].map { [ it[:cost_centre], it[:scenario][:converted] ] }
    assert_equal [ [ @cy.id, "person", "no_level" ] ], result[:unpriced].map { it.values_at(:seat_id, :kind, :reason) }
    assert_equal({ @cy.id => "Cy Quill" }, result[:names])
    assert_not result.key?(:seats)
    assert position_id
  end

  should "give the working of each seat in the unit a caller names, for the scenario and the baseline" do
    result = cost(unit_id: @payments.upcase)

    assert_equal @payments, result[:unit_id]
    ada = result[:seats][:scenario].find { it[:seat_id] == @ada.id }
    assert_equal [ "person", "own", "CC-1", "person", nil, "1", "1", 365, "1", "100000", "100000" ],
                 ada.values_at(:kind, :level_source, :cost_centre, :cost_centre_source, :cost_centre_rule, :fte, :fraction, :days, :share,
                               :base, :amount)
    assert_equal [ "Any location", "EUR", "year", "100000.00" ], ada[:band].values_at(:location, :currency, :period, :midpoint)
    assert_match(/\ASoftware Engineer, .*Senior SWE\z/, ada[:band][:level])
    assert_equal({ starts_on: "2026-01-01", ends_on: "2026-12-31" }, ada[:held])
    assert_equal "No level resolves for the seat", result[:seats][:baseline].find { it[:seat_id] == @cy.id }[:reason_text]
    assert_equal({ @ada.id => "Ada Quill", @cy.id => "Cy Quill" }, result[:names])
  end

  should "leave every figure unconverted without a reference currency, a side with no seats included" do
    ActsAsTenant.with_tenant(@tenant) { ReferenceCurrency.delete_all }
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @year, person_id: @ada.id, placements: [])
    no_unit = cost[:units].find { it[:unit_id].nil? }

    assert_equal [ "100000", {} ], [ no_unit[:scenario][:native]["EUR"], no_unit[:baseline][:native] ]
    assert_equal [ [ nil, [ "There is no reference currency to total in" ] ] ] * 3,
                 no_unit.values_at(:scenario, :baseline, :difference).map { it.values_at(:converted, :missing) }
  end

  context "the see-pay right" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @viewer = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
      end
      call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
    end

    should "show a holder each band's range and everyone else its midpoint, with the same totals while no pay is held" do
      holder = cost(unit_id: @payments)
      viewer = cost(as: @viewer, unit_id: @payments)

      assert_equal %w[band_ranges band_midpoints], [ holder[:pay_view], viewer[:pay_view] ]
      assert_equal %w[0.00 100000.00 200000.00], band_of(holder).values_at(:minimum, :midpoint, :maximum)
      assert_equal [ :midpoint ], band_of(viewer).keys & PayBand::FIGURES
      assert_equal holder[:total], viewer[:total]
      assert_not_includes viewer.to_json, "200000"
    end

    should "give an agent acting for a person exactly that person's view" do
      assert_equal "band_midpoints", cost(as: @viewer)[:pay_view]
      call(Operations::TeamPlanning::GrantSeePay, plan_id: @plan_id, person_id: @viewer.person.id)
      assert_equal "band_ranges", cost(as: @viewer)[:pay_view]
    end

    should "name no figure when it refuses a caller outside the plan" do
      error = assert_raises(Operations::Base::ParameterError) { cost(as: @outsider, unit_id: @payments) }
      assert_equal "No such plan", error.message
    end
  end

  context "actual pay" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @viewer = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
      end
      call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
      call(Operations::TeamPlanning::SetPlanValue, plan_id: @plan_id, scenario_id: @year, person_id: @ada.id, field: "fte", value: "0.8")
    end

    should "scale a full-time figure by a 0.8 FTE, and leave actual pay as it is" do
      { [ "90000", "year", "full_time" ] => "72000", [ "6000", "month", "full_time" ] => "57600",
        [ "60000", "year", "actual" ] => "60000", [ "5000", "month", "actual" ] => "60000" }.each do |(amount, period, basis), base|
        pay(amount:, period:, basis:)
        seat = ada(cost(unit_id: @payments))

        assert_equal [ "actual", basis, "EUR", base, base ], seat.values_at(:pay_source, :basis, :currency, :base, :amount), [ amount, period, basis ].join(" ")
        assert_nil seat[:band]
      end
    end

    should "price the rest of the plan at midpoints, and count the seats priced from actual pay for a holder only" do
      pay(amount: "60000", period: "year", basis: "actual")
      pay(@cy, amount: "50000", period: "year", basis: "actual")
      holder = cost(unit_id: @payments)
      viewer = cost(as: @viewer, unit_id: @payments)

      assert_equal({ scenario: 2, baseline: 0 }, holder[:actual_pay_seats])
      assert_equal "110000", holder[:total][:scenario][:converted]
      assert_equal "100000", holder[:total][:baseline][:converted]

      assert_equal "band_midpoints", viewer[:pay_view]
      assert_not viewer.key?(:actual_pay_seats)
      assert_equal [ "band_midpoint", nil, "80000" ], ada(viewer).values_at(:pay_source, :basis, :amount)
      assert_equal "80000", viewer[:total][:scenario][:converted]
      assert_includes holder.to_json, "60000"
      assert_not_includes viewer.to_json, "60000"
      assert_not_includes viewer.to_json, "50000"
    end

    should "add the unit's on-cost on top of actual pay" do
      call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @year, unit_id: @payments, rule: "on_cost",
                                               value: { "model" => "flat", "params" => { "percent" => "10" } })
      pay(amount: "60000", period: "year", basis: "actual")

      assert_equal [ "60000", "6000", "66000" ], ada(cost(unit_id: @payments)).then { [ it[:base], it[:on_cost][:amount], it[:amount] ] }
    end

    should "not count a seat as priced from actual pay when its on-cost rule refuses it" do
      fixed = { "model" => "itemised", "params" => { "items" => [ { "name" => "Laptop", "amount" => "2000", "currency" => "AUD" } ] } }
      call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @year, unit_id: @payments, rule: "on_cost", value: fixed)
      pay(amount: "60000", period: "year", basis: "actual")
      holder = cost(unit_id: @payments)

      assert_equal [ "actual", "on_cost_refused" ], ada(holder).values_at(:pay_source, :reason)
      assert_equal({ scenario: 0, baseline: 0 }, holder[:actual_pay_seats])
    end

    should "leave a seat unpriced once its held pay is lost with the person's key, with no midpoint standing in" do
      pay(amount: "60000", period: "year", basis: "actual")
      ActsAsTenant.with_tenant(@tenant) { PlanKeyStore.new.destroy_person(@ada.id) }
      holder = cost(unit_id: @payments)

      assert_equal "pay_unknown", ada(holder)[:reason]
      assert_nil ada(holder)[:amount]
      assert_includes holder[:unpriced].map { it[:reason] }, "pay_unknown"
      assert_not_includes cost(as: @viewer).to_json, "pay_unknown"
    end
  end

  def pay(person = @ada, **pay)
    call(Operations::TeamPlanning::SetActualPay, plan_id: @plan_id, scenario_id: @year, person_id: person.id, currency: "EUR", **pay)
  end

  def ada(result) = result[:seats][:scenario].find { it[:seat_id] == @ada.id }

  def band_of(result) = result[:seats][:scenario].find { it[:seat_id] == @ada.id }[:band]

  should "refuse a unit on neither map, the baseline as the scenario, and a caller outside the plan" do
    assert_equal "No such unit", assert_raises(Operations::Base::ParameterError) { cost(unit_id: SecureRandom.uuid_v7) }.message
    assert_match(/baseline has no period/, assert_raises(Operations::Base::ParameterError) { cost(scenario_id: @plan_id) }.message)
    assert_raises(Operations::Base::ParameterError) { cost(as: @outsider) }
  end

  should "read the Org Graph once for the scenario and the baseline together" do
    reads = 0
    as_of = OrgGraph::AsOf.method(:new)
    OrgGraph::AsOf.stub(:new, ->(**args) { reads += 1; as_of.call(**args) }) { cost }

    assert_equal 1, reads
  end
end
