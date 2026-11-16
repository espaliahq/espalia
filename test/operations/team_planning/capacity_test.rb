# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::CapacityTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2026-02-01" }.freeze

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @unit_id = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @family = create(:framework_role_family)
      @engineer = create(:framework_role, code: "E", role_family_id: @family.role_family_id)
      @e5 = create(:framework_level, role_id: @engineer.role_id, ordinal: 5)
      squads = SecureRandom.uuid_v7
      structure.define_taxonomy([ { level_id: squads, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@unit_id, "Payments", level_id: squads, effective_on: "2026-01-01")
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).tap do |people|
        people.record_person(@ada.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0)
        people.set_membership(@ada.id, @unit_id, **ESPALIA, allocation: Rational(1, 3).to_f)
      end
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
  end

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def capacity(as: @admin) = call(Operations::TeamPlanning::Capacity, as:, plan_id: @plan_id, scenario_id: @plan_id)

  should "show each seat's places and working as decimal strings, totals per model, and name the people" do
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person)
      TeamPlanning::CommandHandler.new(actor: context).set_change(
        @plan_id, TeamPlanning::Events::RuleSet, scenario_id: @plan_id, subject_id: @plan_id,
                                                 end_state: { rule: "capacity_model", value: { families: { @family.role_family_id => { model: "per_fte" } } } }
      )
    end
    call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @plan_id, role_id: @engineer.role_id,
                                                level_id: @e5.level_id, unit_id: @unit_id, fte: 0.5, basis: "new")
    result = capacity

    ada = result[:seats].find { it[:seat_id] == @ada.id }
    place = ada[:places].first
    assert_equal [ "person", "1", true ], ada.values_at(:kind, :fte, :fte_known)
    assert_equal [ @unit_id, @engineer.role_id, @e5.level_id, "per_fte", "family" ],
                 place.values_at(:unit_id, :role_id, :level_id, :model, :chosen_for)
    assert_equal place[:allocation], place[:capacity]
    assert_equal [ "FTE", "1" ], place[:working].first.values_at(:label, :amount)
    assert_match(/\A0\.3333/, place[:capacity])
    assert_equal "0.5", result[:seats].find { it[:kind] == "position" }[:places].first[:capacity]
    assert_equal [ "per_fte" ], result[:totals].keys
    assert_equal({ "per_fte" => { symbol: "FTE", description: TeamPlanning::CapacityModels::PerFte.description } }, result[:models])
    assert_equal [ { unit_id: @unit_id, name: "Payments", totals: result[:totals], parts: result[:parts] } ], result[:units]
    assert_equal({ actual: result[:totals], planned: {}, forecast: {} }, result[:parts])
    assert_equal({ @ada.id => "Ada Quill" }, result[:names])
    assert_empty result[:unclassified]
  end

  should "list a unit everyone left, with its negative planned part" do
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @plan_id, rule: "capacity_model",
                                            value: { roles: { @engineer.role_id => { model: "per_fte" } } })
    year = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "2026", ends_on: "2026-12-31")[:scenario_id]
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: year, person_id: @ada.id, placements: [])
    payments = call(Operations::TeamPlanning::Capacity, plan_id: @plan_id, scenario_id: year)[:units].find { it[:unit_id] == @unit_id }

    assert_equal({}, payments[:totals])
    assert_match(/\A-0\.3333/, payments[:parts][:planned]["per_fte"])
  end

  should "name a model only a forecast uses, so every figure has its symbol" do
    hiring = Class.new(TeamPlanning::ForecastKind) do
      def self.rule_name = "test_units_hiring"
      def self.description = "A fixed forecast in units"
      def self.default = {}
      def self.forecast(frame) = [ frame.row(unit_id: nil, headcount: 1r, capacity: { "units" => 1r }) ]
    end
    TeamPlanning::RuleKinds.register(hiring)
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @plan_id, rule: "capacity_model",
                                            value: { roles: { @engineer.role_id => { model: "per_fte" } } })
    year = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "2026", ends_on: "2026-12-31")[:scenario_id]
    result = call(Operations::TeamPlanning::Capacity, plan_id: @plan_id, scenario_id: year)

    assert_equal "1", result[:parts][:forecast]["units"]
    assert_equal %w[per_fte units], result[:models].keys
  ensure
    TeamPlanning::RuleKinds.unregister(hiring)
  end

  should "show each working step's op and subject, and a figure's overload and notes, as the units model gives them" do
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person)
      TeamPlanning::CommandHandler.new(actor: context).set_change(
        @plan_id, TeamPlanning::Events::RuleSet, scenario_id: @plan_id, subject_id: @plan_id,
                                                 end_state: { rule: "capacity_model", value: { families: { @family.role_family_id => { model: "units" } } } }
      )
    end
    position_id = call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @plan_id, role_id: @engineer.role_id,
                                                              level_id: @e5.level_id, unit_id: @unit_id, fte: 1, basis: "new")[:position_id]
    open_seat = capacity[:seats].find { it[:seat_id] == position_id }[:places].first

    assert_equal [ { label: "Base at L5", amount: "1.45", op: "+", subject_id: nil }, { label: "Units", amount: "1.45", op: "=", subject_id: nil } ],
                 open_seat[:working]
    assert_equal [ false, "0" ], open_seat.values_at(:overloaded, :excess)
    assert_equal [ "unattributed_no_manager" ], open_seat[:notes].map { it[:note] }
    assert_match "counts against nobody", open_seat[:notes].first[:text]
  end

  should "leave a model no longer registered out of models, its place unclassified" do
    model = Class.new(TeamPlanning::CapacityModel) do
      def self.model_name = "test_gone"
      def self.description = "Gone soon"
    end
    TeamPlanning::CapacityModels.register(model)
    ActsAsTenant.with_tenant(@tenant) do
      TeamPlanning::CommandHandler.new(actor: AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person)).set_change(
        @plan_id, TeamPlanning::Events::RuleSet, scenario_id: @plan_id, subject_id: @plan_id,
                                                 end_state: { rule: "capacity_model", value: { families: { @family.role_family_id => { model: "test_gone" } } } }
      )
    end
    TeamPlanning::CapacityModels.unregister(model)
    result = capacity

    assert_empty result[:models]
    assert_equal [ "unknown_model" ], result[:unclassified].pluck(:reason)
  ensure
    TeamPlanning::CapacityModels.unregister(model) if TeamPlanning::CapacityModels.registered?("test_gone")
  end

  should "list every seat as unclassified, with why, until a model is chosen" do
    result = capacity

    assert_empty result[:totals]
    assert_empty result[:models]
    assert_equal [ [ @ada.id, "person", @unit_id, "no_model" ] ],
                 result[:unclassified].map { it.values_at(:seat_id, :kind, :unit_id, :reason) }
    assert_equal TeamPlanning::Capacity::REASONS["no_model"], result[:unclassified].first[:reason_text]
  end

  should "show a level the plan cleared to follow the Org Graph as unresolved, while the baseline still counts it" do
    call(Operations::TeamPlanning::SetRule, plan_id: @plan_id, scenario_id: @plan_id, rule: "capacity_model",
                                            value: { families: { @family.role_family_id => { model: "units" } } })
    year = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "2026", ends_on: "2026-12-31")[:scenario_id]
    people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    call(Operations::TeamPlanning::SetPlannedLevel, plan_id: @plan_id, scenario_id: year, person_id: @ada.id, level: "4")
    travel_to Time.utc(2026, 3, 10, 9)
    ActsAsTenant.with_tenant(@tenant) { people.change_level(@ada.id, "6", provider: "espalia", effective_on: "2026-03-10") }
    call(Operations::TeamPlanning::RebasePlan, plan_id: @plan_id, base_on: "2026-03-02")
    travel_to Time.utc(2026, 3, 11, 9)
    ActsAsTenant.with_tenant(@tenant) { people.change_level(@ada.id, nil, provider: "espalia", effective_on: "2026-03-11") }
    call(Operations::TeamPlanning::SettleConflict, plan_id: @plan_id, scenario_id: year, subject_id: @ada.id, facet: "level", choice: "reality")

    place = ->(scenario_id) { call(Operations::TeamPlanning::Capacity, plan_id: @plan_id, scenario_id:)[:seats].find { it[:seat_id] == @ada.id }[:places].first }
    assert_equal [ @engineer.role_id, nil, "units", "no_level" ], place.call(year).values_at(:role_id, :level_id, :model, :reason)
    assert_equal [ @e5.level_id, nil ], place.call(@plan_id).values_at(:level_id, :reason)
    assert_equal [ [ @ada.id, "no_level" ] ],
                 call(Operations::TeamPlanning::Capacity, plan_id: @plan_id, scenario_id: year)[:unclassified].map { it.values_at(:seat_id, :reason) }
  end

  should "refuse a scenario the plan doesn't have, and a caller who isn't in the plan, as the web and MCP both see it" do
    assert_raises(Operations::Base::ParameterError) do
      call(Operations::TeamPlanning::Capacity, plan_id: @plan_id, scenario_id: SecureRandom.uuid_v7)
    end
    assert_equal "No such plan", assert_raises(Operations::Base::ParameterError) { capacity(as: @outsider) }.message
  end
  should "name a placeholder hire by its label, so the working says who a figure is for" do
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person)
      TeamPlanning::CommandHandler.new(actor: context).set_change(
        @plan_id, TeamPlanning::Events::RuleSet, scenario_id: @plan_id, subject_id: @plan_id,
                                                 end_state: { rule: "capacity_model", value: { families: { @family.role_family_id => { model: "per_fte" } } } }
      )
    end
    position_id = call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @plan_id, role_id: @engineer.role_id,
                                                              level_id: @e5.level_id, unit_id: @unit_id, fte: 1, basis: "new")[:position_id]
    hire_id = call(Operations::TeamPlanning::SetPlaceholderHire, plan_id: @plan_id, scenario_id: @plan_id,
                                                                 label: "Payments engineer", level: "5", fte: 1)[:placeholder_id]
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @plan_id, person_id: hire_id,
                                                  placements: [ { position_id:, allocation: 1 } ])
    result = capacity

    assert_equal "person", result[:seats].find { it[:seat_id] == hire_id }[:kind]
    assert_equal "Payments engineer", result[:names][hire_id]
  end
end
