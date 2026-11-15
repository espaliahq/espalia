# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::CapacityOverrideTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2026-02-01" }.freeze
  OVERRIDE = Operations::TeamPlanning::SetCapacityOverride

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @unit_id = SecureRandom.uuid_v7
    @growth = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @family = create(:framework_role_family)
      @engineer = create(:framework_role, code: "E", role_family_id: @family.role_family_id)
      create(:framework_level, role_id: @engineer.role_id, ordinal: 5)
      squads = SecureRandom.uuid_v7
      structure.define_taxonomy([ { level_id: squads, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@unit_id, "Payments", level_id: squads, effective_on: "2026-01-01")
      structure.create_unit(@growth, "Growth", level_id: squads, effective_on: "2026-01-01")
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).tap do |people|
        people.record_person(@ada.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0)
        people.set_membership(@ada.id, @unit_id, **ESPALIA, allocation: Rational(1, 3).to_f)
      end
      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    as_tenant do
      context = AuthorizationContext.new(user: @editor.user, tenant_user: @editor, person: @editor.person)
      TeamPlanning::CommandHandler.new(actor: context).set_change(
        @plan_id, TeamPlanning::Events::RuleSet, scenario_id: @plan_id, subject_id: @plan_id,
                                                 end_state: { rule: "capacity_model", value: { families: { @family.role_family_id => { model: "per_fte" } } } }
      )
    end
    @q1 = fork(relation: "then", name: "Q1", ends_on: "2026-06-30")
    @q2 = fork(parent_id: @q1, relation: "then", name: "Q2", ends_on: "2026-09-30")
  end

  def as_tenant(tenant = @tenant, &) = ActsAsTenant.with_tenant(tenant, &)

  def call(operation, as: @editor, tenant: @tenant, **params)
    as_tenant(tenant) { operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:) }
  end

  def fork(**params) = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, **params)[:scenario_id]

  def write(operation, scenario_id: @q1, **params) = call(operation, plan_id: @plan_id, scenario_id:, **params)

  def override(amount, scenario_id: @q1, **place) = write(OVERRIDE, scenario_id:, person_id: @ada.id, **(place.presence || { unit_id: @unit_id }), amount:)

  def refusal(operation = OVERRIDE, as: @editor, tenant: @tenant, **params)
    assert_raises(Operations::Base::ParameterError) { call(operation, as:, tenant:, plan_id: @plan_id, scenario_id: @q1, **params) }.message
  end

  def place_of_ada(scenario_id = @q2)
    capacity = call(Operations::TeamPlanning::Capacity, plan_id: @plan_id, scenario_id:)
    capacity[:seats].find { it[:seat_id] == @ada.id }[:places].first.merge(totals: capacity[:totals], unclassified: capacity[:unclassified])
  end

  def attention(scenario_id = @q2) = call(Operations::TeamPlanning::Attention, plan_id: @plan_id, scenario_id:)[:items]

  def capacity_items = attention.select { it[:facet].start_with?("capacity:") }

  should "price a place at the override in the step it is set and those after, with the calculated figure behind it" do
    assert_equal({ plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, position_id: nil, unit_id: @unit_id, amount: "0.8" },
                 override(" 0.8 "))

    place = place_of_ada
    assert_equal [ "0.8", { "per_fte" => "0.8" } ], place.values_at(:capacity, :totals)
    assert_match(/\A0\.3333/, place[:calculated])
    assert_equal({ label: "Planner's override, in place of 0.3333", amount: "0.8", op: "=", subject_id: nil }, place[:working].last)
    assert_nil place_of_ada(@plan_id)[:calculated]
    assert_equal({ value: "0.8" }, call(Operations::TeamPlanning::ScenarioMap, plan_id: @plan_id, scenario_id: @q2)[:people]
                                     .find { it[:id] == @ada.id }[:capacity_overrides][@unit_id])
  end

  should "leave the model's overload and notes behind on the calculated figure" do
    model = TeamPlanning::CapacityModels.fetch("per_fte")
    floored = Class.new do
      define_method(:notes) { model.notes }
      define_method(:symbol) { model.symbol }
      define_method(:description) { model.description }
      define_method(:capacity_of) do |*, **|
        TeamPlanning::CapacityModel::Figure.new(amount: 0r, working: [], overloaded: true, excess: 1r, notes: [ "unattributed_no_manager" ])
      end
    end.new
    override("0.8")

    place = TeamPlanning::CapacityModels.stub(:fetch, floored) { place_of_ada }
    assert_equal [ "0.8", "0", false, "0", [] ], place.values_at(:capacity, :calculated, :overloaded, :excess, :notes)
    assert_equal [ true, "1", [ "unattributed_no_manager" ] ],
                 place[:calculated_diagnostics].values_at(:overloaded, :excess).push(place[:calculated_diagnostics][:notes].pluck(:note))
    assert_equal "Planner's override, in place of 0", place[:working].last[:label]
  end

  should "let an alternative override its parent's override, and clear one back to the model" do
    override("0.8")
    alternative = fork(parent_id: @q1, relation: "instead", name: "Lean Q1")
    override("0.5", scenario_id: alternative)
    assert_equal [ "0.5", "0.8" ], [ place_of_ada(alternative)[:capacity], place_of_ada(@q1)[:capacity] ]

    write(Operations::TeamPlanning::ClearChange, subject_id: @ada.id, facet: "capacity:#{@unit_id}")
    assert_match(/\A0\.3333/, place_of_ada[:capacity])
    assert_nil place_of_ada[:calculated]
  end

  should "mark an override on a place that counts nowhere for another reason, and leave the place's reason" do
    override("0.8")
    write(Operations::TeamPlanning::SetDeparture, scenario_id: @q2, person_id: @ada.id)

    place = place_of_ada
    assert_equal [ nil, "leaving", true ], place.values_at(:capacity, :reason, :overridden)
    assert_equal [ true ], place[:unclassified].map { it[:overridden] }
    assert_equal [ "0.8", true ], place_of_ada(@q1).values_at(:capacity, :overridden)
    assert_not place_of_ada(@plan_id)[:overridden]
  end

  should "refuse to pin an override, since the plan keeps it private" do
    override("0.8")
    message = assert_raises(Operations::Base::ParameterError) do
      write(Operations::TeamPlanning::PinChange, scenario_id: @q2, subject_id: @ada.id, facet: "capacity:#{@unit_id}")
    end.message
    assert_match "can't be pinned", message
  end

  should "count a forgotten person's overridden place nowhere, never at the model's figure" do
    override("0.8")
    as_tenant { PlanKeyStore.new.destroy_person(@ada.id) }

    place = place_of_ada
    assert_equal [ nil, "override_unknown", {} ], place.values_at(:capacity, :reason, :totals)
    assert_match(/\A0\.3333/, place[:calculated])
    assert_equal [ [ @ada.id, "override_unknown" ] ], place[:unclassified].map { it.values_at(:seat_id, :reason) }
  end

  should "flag an override on a place the person no longer holds, and leave it unflagged while they hold it" do
    override("0.8")
    override("0.4", unit_id: @growth)
    assert_equal [ [ @ada.id, "capacity:#{@growth}", "Overrides capacity in a place they don't hold" ] ],
                 capacity_items.map { it.values_at(:subject_id, :facet, :reason) }

    write(Operations::TeamPlanning::SetAssignment, scenario_id: @q2, person_id: @ada.id, placements: [ { unit_id: @growth, allocation: 1 } ])
    assert_equal [ "capacity:#{@unit_id}" ], capacity_items.map { it[:facet] }
    assert_equal "0.4", place_of_ada[:capacity]
  end

  should "refuse a malformed override, a person the tenant doesn't hold, a viewer and another tenant's admin" do
    assert_equal "An override is a number of units, 0 or more", refusal(person_id: @ada.id, unit_id: @unit_id, amount: "-1")
    assert_equal "An override is for a position or a unit, not both",
                 refusal(person_id: @ada.id, unit_id: @unit_id, position_id: SecureRandom.uuid_v7, amount: "1")
    assert_match "must be a UUID", refusal(person_id: @ada.id, unit_id: "payments", amount: "1")
    assert_equal "No such person", refusal(person_id: SecureRandom.uuid_v7, unit_id: @unit_id, amount: "1")
    hire = write(Operations::TeamPlanning::SetPlaceholderHire, label: "Payments engineer")[:placeholder_id]
    assert_equal "No such person", refusal(person_id: hire, unit_id: @unit_id, amount: "1")

    other = create(:tenant)
    outsider = as_tenant(other) { create(:tenant_user, tenant: other, role: :admin, person: create(:person, tenant: other)) }
    [ [ @viewer, @tenant ], [ outsider, other ] ].each do |as, tenant|
      assert_equal "No such plan", refusal(as:, tenant:, person_id: @ada.id, unit_id: @unit_id, amount: "1")
    end
    assert_nil place_of_ada[:calculated]
  end
end
