# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::AssignmentsTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  BASE_ON = Date.new(2026, 3, 2)

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @payments = SecureRandom.uuid_v7
    @growth = SecureRandom.uuid_v7
    level = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant, name: "Edie Marsh"))
      @other_admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant, name: "Vic Arden"))
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      @bo = create(:person, tenant: @tenant, name: "Bo Reyes")
      @newcomer = create(:person, tenant: @tenant, name: "Nia Newcomer")
      @leaver = create(:person, tenant: @tenant, name: "Lee Gone")
      @engineer = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      @e2 = create(:framework_level, tenant: @tenant, role_id: @engineer.role_id, ordinal: 2, title: "Engineer II")
      structure.define_taxonomy([ { level_id: level, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: level, effective_on: "2026-01-01")
      structure.create_unit(@growth, "Growth", level_id: level, effective_on: "2026-01-01")
      handler.record_person(@ada.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", fte: 0.8)
      handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0, role: "Lead")
      handler.record_person(@bo.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed")
      handler.set_membership(@bo.id, @payments, **ESPALIA, effective_on: "2026-02-01")
      OrgLeaver.create!(tenant: @tenant, person_id: @leaver.id, left_on: "2026-01-15")
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: BASE_ON.iso8601)[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @q1 = fork(relation: "then", name: "Q1", ends_on: "2026-06-30")
    @lean = fork(parent_id: @q1, relation: "instead", name: "Lean Q1")
    @q2 = fork(parent_id: @q1, relation: "then", name: "Q2", ends_on: "2026-09-30")
  end

  def call(operation, as: @editor, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def fork(**params) = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, **params)[:scenario_id]

  def assign(scenario_id, person, *placements, as: @editor)
    call(Operations::TeamPlanning::SetAssignment, as:, plan_id: @plan_id, scenario_id:, person_id: person.id, placements:)
  end

  def map(scenario_id, as: @editor) = call(Operations::TeamPlanning::ScenarioMap, as:, plan_id: @plan_id, scenario_id:)

  def places(scenario_id, person) = map(scenario_id)[:people].find { it[:id] == person.id }[:memberships]

  def units_of(scenario_id, person) = places(scenario_id, person).pluck(:unit_id)

  def open_position(scenario_id, unit_id: @payments, **params)
    call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id:, role_id: @engineer.role_id,
                                                level_id: @e2.level_id, unit_id:, fte: 1, basis: "new", **params)[:position_id]
  end

  def refusal(as: @editor, **params)
    assert_raises(Operations::Base::ParameterError) do
      call(Operations::TeamPlanning::SetAssignment, as:, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, **params)
    end.message
  end

  should "move a person in a step, for the steps after it and never the scenario before" do
    moved = assign(@q1, @ada, { unit_id: @growth, allocation: 1, role: "Lead" })

    assert_equal({ plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id,
                   placements: [ { position_id: nil, unit_id: @growth, allocation: 1.0, role: "Lead" } ], allocation_total: 1.0 }, moved)
    assert_equal [ @payments ], units_of(@plan_id, @ada)
    [ @q1, @lean, @q2 ].each { assert_equal [ @growth ], units_of(it, @ada) }
  end

  should "let an alternative move someone its parent placed, leaving the parent alone" do
    assign(@q1, @ada, { unit_id: @growth, allocation: 1 })
    assign(@lean, @ada, { unit_id: @payments, allocation: 0.5 }, { unit_id: @growth, allocation: 0.5 })

    assert_equal [ @growth ], units_of(@q1, @ada)
    assert_equal [ @payments, @growth ], units_of(@lean, @ada)
  end

  should "give a child the whole list once it changes one placement" do
    assign(@q1, @ada, { unit_id: @payments, allocation: 0.5 }, { unit_id: @growth, allocation: 0.5 })
    assign(@q2, @ada, { unit_id: @growth, allocation: 1 })
    assign(@q1, @ada, { unit_id: @payments, allocation: 0.2 }, { unit_id: @growth, allocation: 0.8 })

    assert_equal [ [ @growth, 1.0 ] ], places(@q2, @ada).map { it.values_at(:unit_id, :allocation) }
  end

  should "move a position's people with the position" do
    position_id = open_position(@q1)
    assign(@q1, @bo, { position_id:, allocation: 1 })
    assert_equal [ @payments ], units_of(@q1, @bo)

    open_position(@q2, position_id:, unit_id: @growth)
    assert_equal [ [ position_id, @growth ] ], places(@q2, @bo).map { it.values_at(:position_id, :unit_id) }
  end

  should "split a person's allocation, and accept a total over 1 with the total on the map" do
    assign(@q1, @ada, { unit_id: @payments, allocation: 0.6 }, { unit_id: @growth, allocation: 0.4 })
    assert_in_delta 1.0, map(@q1)[:people].find { it[:id] == @ada.id }[:allocation_total]

    over = assign(@q1, @ada, { unit_id: @payments, allocation: 1 }, { unit_id: @growth, allocation: 0.5 })
    assert_in_delta 1.5, over[:allocation_total]
    assert_in_delta 1.5, map(@q1)[:people].find { it[:id] == @ada.id }[:allocation_total]
  end

  should "read a total as unknown, not under-allocated, when the HRIS gave no allocation" do
    assert_nil map(@plan_id)[:people].find { it[:id] == @bo.id }[:allocation_total]
  end

  should "put someone with an empty assignment in Unassigned" do
    assign(@q1, @ada)

    assert_includes map(@q1)[:unassigned_ids], @ada.id
    assert_not_includes map(@plan_id)[:unassigned_ids], @ada.id
  end

  should "keep a placement in a closed position, with no unit, so the person is unassigned" do
    position_id = open_position(@q1)
    assign(@q1, @bo, { position_id:, allocation: 1 })
    call(Operations::TeamPlanning::ClosePosition, plan_id: @plan_id, scenario_id: @q2, position_id:)

    assert_equal [ [ position_id, nil ] ], places(@q2, @bo).map { it.values_at(:position_id, :unit_id) }
    assert_includes map(@q2)[:unassigned_ids], @bo.id
  end

  should "name a position's occupants and its open FTE, an unknown FTE counting as full time" do
    position_id = open_position(@q1)
    assign(@q1, @ada, { position_id:, allocation: 0.5, role: "Lead" })
    assign(@q1, @bo, { position_id:, allocation: 0.25 })

    positions = call(Operations::TeamPlanning::Positions, plan_id: @plan_id, scenario_id: @q1)
    position = positions[:positions].sole
    assert_equal [ [ @ada.id, 0.5, "Lead" ], [ @bo.id, 0.25, nil ] ],
                 position[:occupants].map { it.values_at(:person_id, :allocation, :role) }
    assert_in_delta 1 - (0.5 * 0.8) - 0.25, position[:open_fte]
    assert_equal({ @ada.id => "Ada Quill", @bo.id => "Bo Reyes" }, positions[:names])
  end

  should "list a person not on the map as unresolved, saying why" do
    assign(@q1, @newcomer, { unit_id: @growth, allocation: 1 })
    assign(@q1, @leaver, { unit_id: @growth, allocation: 1 })

    resolved = map(@q1)
    assert_equal [ [ @newcomer.id, "joined after the base date" ], [ @leaver.id, "has left" ] ],
                 resolved[:unresolved].map { it.values_at(:person_id, :why) }
    assert_equal "Nia Newcomer", resolved[:names].fetch(@newcomer.id)
    assert_not_includes resolved[:people].pluck(:id), @newcomer.id
  end

  should "name a forgotten person as a former member" do
    assign(@q1, @ada, { unit_id: @growth, allocation: 1 })
    ActsAsTenant.with_tenant(@tenant) { @ada.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current) }

    assert_equal Person::FORMER_MEMBER, map(@q1)[:names].fetch(@ada.id)
  end

  should "refuse a placement in both a position and a unit, or neither, and an allocation outside (0, 1]" do
    position_id = open_position(@q1)
    assert_equal "A placement is in a position or a unit, not both",
                 refusal(placements: [ { position_id:, unit_id: @growth, allocation: 1 } ])
    assert_equal "A placement names a position or a unit", refusal(placements: [ { allocation: 1 } ])
    [ 0, 1.5, -0.2, "lots" ].each do |allocation|
      assert_equal "An allocation is above 0 and at most 1", refusal(placements: [ { unit_id: @growth, allocation: } ]), allocation.to_s
    end
    assert_equal "A person holds each position and unit once",
                 refusal(placements: [ { unit_id: @growth, allocation: 0.5 }, { unit_id: @growth, allocation: 0.5 } ])
  end

  should "refuse a position the scenario lacks, and a person outside the tenant" do
    elsewhere = create(:person, tenant: create(:tenant))

    assert_equal "This scenario has no such position", refusal(placements: [ { position_id: open_position(@q2), allocation: 1 } ])
    assert_equal "No such person", refusal(person_id: elsewhere.id, placements: [ { unit_id: @growth, allocation: 1 } ])
  end

  should "read as missing to an admin outside the plan, and refuse a viewer's write" do
    assert_equal "No such plan", refusal(as: @other_admin, placements: [])
    assert_equal "No such plan", refusal(as: @viewer, placements: [])
    assert_raises(Operations::Base::ParameterError) { map(@q1, as: @other_admin) }
    assert_equal [ @payments ], map(@q1, as: @viewer)[:people].find { it[:id] == @ada.id }[:memberships].pluck(:unit_id)
  end
end
