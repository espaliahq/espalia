# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::PlanDataTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  BASE_ON = Date.new(2026, 3, 2)

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @payments = SecureRandom.uuid_v7
    squad = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      structure.define_taxonomy([ { level_id: squad, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: squad, effective_on: "2026-01-01")
      handler.record_person(@ada.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", level: "3")
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: BASE_ON.iso8601)[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @q1 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]
    @q2 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2", ends_on: "2026-09-30")[:scenario_id]
  end

  def as_tenant(tenant = @tenant, &) = ActsAsTenant.with_tenant(tenant, &)

  def call(operation, as: @editor, tenant: @tenant, **params)
    as_tenant(tenant) { operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:) }
  end

  def write(operation, scenario_id: @q1, **params) = call(operation, plan_id: @plan_id, scenario_id:, **params)

  def refusal(operation, as: @editor, tenant: @tenant, **params)
    assert_raises(Operations::Base::ParameterError) { call(operation, as:, tenant:, plan_id: @plan_id, scenario_id: @q1, **params) }.message
  end

  def map(scenario_id = @q2) = call(Operations::TeamPlanning::ScenarioMap, plan_id: @plan_id, scenario_id:)

  def person_in(id, scenario_id = @q2) = map(scenario_id)[:people].find { it[:id] == id }

  should "plan a promotion and correct an FTE, both shown on the map for the steps after" do
    assert_equal({ plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, level: "4" },
                 write(Operations::TeamPlanning::SetPlannedLevel, person_id: @ada.id, level: " 4 "))
    assert_equal({ plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, field: "fte", value: 0.8 },
                 write(Operations::TeamPlanning::SetPlanValue, person_id: @ada.id, field: "fte", value: "0.8"))

    ada = person_in(@ada.id)
    assert_equal [ { value: "4" }, { fte: { value: 0.8 } }, "3" ], [ ada[:planned_level], ada[:plan_data], ada[:level] ]
    assert_nil person_in(@ada.id, @plan_id)[:planned_level]
  end

  should "add a placeholder hire named by its label, change it, and place it" do
    added = write(Operations::TeamPlanning::SetPlaceholderHire, label: "Payments engineer", level: "3", fte: 0.5)
    hire = added[:placeholder_id]
    write(Operations::TeamPlanning::SetPlaceholderHire, placeholder_id: hire, label: "Payments lead", level: "4")
    write(Operations::TeamPlanning::SetAssignment, scenario_id: @q2, person_id: hire, placements: [ { unit_id: @payments, allocation: 1 } ])

    payload = map
    assert_equal "Payments lead", payload[:names].fetch(hire)
    placeholder = payload[:people].find { it[:id] == hire }
    assert_equal [ { value: "Payments lead" }, { level: { value: "4" } } ], [ placeholder[:placeholder], placeholder[:plan_data] ]
    assert_equal [ @payments ], placeholder[:memberships].map { it[:unit_id] }
  end

  should "refuse a person or placeholder the tenant or scenario doesn't hold, and a value the plan can't take" do
    assert_equal "No such person", refusal(Operations::TeamPlanning::SetPlannedLevel, person_id: SecureRandom.uuid_v7, level: "4")
    assert_equal "This scenario has no such placeholder hire",
                 refusal(Operations::TeamPlanning::SetPlaceholderHire, placeholder_id: SecureRandom.uuid_v7, label: "Lead")
    assert_equal "An FTE is above 0 and at most 1", refusal(Operations::TeamPlanning::SetPlanValue, person_id: @ada.id, field: "fte", value: "1.5")
    assert_equal "A plan value is a person's level or fte, not salary", refusal(Operations::TeamPlanning::SetPlanValue, person_id: @ada.id, field: "salary", value: "1")
    assert_equal "No such person", refusal(Operations::TeamPlanning::SetAssignment, person_id: SecureRandom.uuid_v7, placements: [])
  end

  should "refuse a viewer and another tenant's admin, as for every plan write" do
    other = create(:tenant)
    outsider = as_tenant(other) { create(:tenant_user, tenant: other, role: :admin, person: create(:person, tenant: other)) }

    [ [ @viewer, @tenant ], [ outsider, other ] ].each do |as, tenant|
      assert_equal "No such plan", refusal(Operations::TeamPlanning::SetPlannedLevel, as:, tenant:, person_id: @ada.id, level: "4")
      assert_equal "No such plan", refusal(Operations::TeamPlanning::SetPlanValue, as:, tenant:, person_id: @ada.id, field: "level", value: "4")
      assert_equal "No such plan", refusal(Operations::TeamPlanning::SetPlaceholderHire, as:, tenant:, label: "Lead")
    end
    assert_nil person_in(@ada.id)[:planned_level]
  end

  should "read a forgotten person's values as removed, and keep a placeholder" do
    write(Operations::TeamPlanning::SetPlannedLevel, person_id: @ada.id, level: "4")
    hire = write(Operations::TeamPlanning::SetPlaceholderHire, label: "Payments engineer")[:placeholder_id]
    as_tenant { PlanKeyStore.new.destroy_person(@ada.id) }

    assert_equal({ removed: true }, person_in(@ada.id)[:planned_level])
    assert_equal "Payments engineer", map[:names].fetch(hire)
  end
end
