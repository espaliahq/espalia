# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::MovePlaceTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @payments = SecureRandom.uuid_v7
    @growth = SecureRandom.uuid_v7
    @platform = SecureRandom.uuid_v7
    level = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      @bo = create(:person, tenant: @tenant, name: "Bo Reyes")
      @cy = create(:person, tenant: @tenant, name: "Cy Loner")
      @engineer = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      @e2 = create(:framework_level, tenant: @tenant, role_id: @engineer.role_id, ordinal: 2, title: "Engineer II")
      structure.define_taxonomy([ { level_id: level, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: level, effective_on: "2026-01-01")
      structure.create_unit(@growth, "Growth", level_id: level, effective_on: "2026-01-01")
      structure.create_unit(@platform, "Platform", level_id: level, effective_on: "2026-01-01")
      handler.record_person(@ada.id, **ESPALIA, effective_on: "2026-01-02", employment_status: "employed")
      handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-01-02", allocation: 0.6, role: "Lead")
      handler.set_membership(@ada.id, @platform, **ESPALIA, effective_on: "2026-01-02", allocation: 0.4)
      handler.record_person(@bo.id, **ESPALIA, effective_on: "2026-01-02", employment_status: "employed")
      handler.set_membership(@bo.id, @payments, **ESPALIA, effective_on: "2026-01-02")
      handler.record_person(@cy.id, **ESPALIA, effective_on: "2026-01-02", employment_status: "employed")
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @q1 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]
  end

  def call(operation, as: @editor, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def move(person, as: @editor, scenario_id: @q1, **params)
    call(Operations::TeamPlanning::MovePlace, as:, plan_id: @plan_id, scenario_id:, person_id: person.id, **params)
  end

  def places(person, scenario_id: @q1)
    call(Operations::TeamPlanning::ScenarioMap, plan_id: @plan_id, scenario_id:)[:people]
      .find { it[:id] == person.id }[:memberships].map { it.slice(:position_id, :unit_id, :allocation, :role).compact }
  end

  def open_position(unit_id: @growth)
    call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @q1, role_id: @engineer.role_id,
                                                level_id: @e2.level_id, unit_id:, fte: 1, basis: "new")[:position_id]
  end

  def refusal(person = @ada, **params)
    assert_raises(Operations::Base::ParameterError) { move(person, **params) }.message
  end

  should "move the one place dragged and keep the person's others" do
    move(@ada, from_unit_id: @payments, to_unit_id: @growth, allocation: 0.5, role: "Lead")

    assert_equal [ { unit_id: @platform, allocation: 0.4 }, { unit_id: @growth, allocation: 0.5, role: "Lead" } ], places(@ada)
    assert_equal [ @payments, @platform ].sort, places(@ada, scenario_id: @plan_id).pluck(:unit_id).sort
  end

  should "drop the place on Unassigned, leaving someone with no other place unassigned" do
    move(@ada, from_unit_id: @payments, to_unit_id: "unassigned")
    move(@bo, from_unit_id: @payments, to_unit_id: "unassigned")

    assert_equal [ { unit_id: @platform, allocation: 0.4 } ], places(@ada)
    assert_empty places(@bo)
  end

  should "place someone from Unassigned, and write an HRIS place with no allocation at its share" do
    move(@cy, from_unit_id: "unassigned", to_unit_id: @growth, allocation: 1)
    move(@bo, from_unit_id: @payments, to_unit_id: @payments, allocation: 0.5)

    assert_equal [ { unit_id: @growth, allocation: 1.0 } ], places(@cy)
    assert_equal [ { unit_id: @payments, allocation: 0.5 } ], places(@bo)
  end

  should "replace a place the person already holds in the unit they move to" do
    move(@ada, from_unit_id: @payments, to_unit_id: @platform, allocation: 1)

    assert_equal [ { unit_id: @platform, allocation: 1.0 } ], places(@ada)
  end

  should "keep the move's note on the assignment it writes, under the person's key" do
    move(@ada, from_unit_id: @payments, to_unit_id: @growth, allocation: 0.5, note: "Growth needs a lead")

    override = ActsAsTenant.with_tenant(@tenant) { TeamPlanningOverride.find_by!(scenario_id: @q1, subject_id: @ada.id, facet: "assignment") }
    assert_equal "Growth needs a lead", override.note.reveal
    assert_equal PlanKeyStore.person_identifier(@tenant.id, @plan_id, @ada.id), override.read_attribute(:note)["identifier"]
  end

  should "refuse Today, a viewer, a place the person doesn't hold, a unit the scenario lacks and a move with no allocation" do
    assert_match "Today can't be edited", refusal(scenario_id: @plan_id, from_unit_id: @payments, to_unit_id: @growth, allocation: 1)
    assert_equal "No such plan", refusal(as: @viewer, from_unit_id: @payments, to_unit_id: @growth, allocation: 1)
    assert_equal "Ada Quill holds no such place", refusal(from_unit_id: @growth, to_unit_id: @payments, allocation: 1)
    assert_equal "allocation is required", refusal(from_unit_id: @payments, to_unit_id: @growth)
    assert_equal "Ada Quill holds no such place", refusal(from_unit_id: "unassigned", to_unit_id: @growth, allocation: 1)
    assert_equal "This scenario has no such unit", refusal(from_unit_id: @payments, to_unit_id: SecureRandom.uuid_v7, allocation: 1)
    assert_equal [ @payments, @platform ].sort, places(@ada).pluck(:unit_id).sort
  end

  context "into a position" do
    setup { @position = open_position }

    should "place the person in the position, replacing a place they already hold there" do
      move(@cy, from_unit_id: "unassigned", to_position_id: @position, allocation: 0.5)
      move(@ada, from_unit_id: @payments, to_position_id: @position, allocation: 1, role: "Lead")
      move(@ada, from_unit_id: @platform, to_position_id: @position, allocation: 0.4)

      assert_equal [ { position_id: @position, unit_id: @growth, allocation: 0.5 } ], places(@cy)
      assert_equal [ { position_id: @position, unit_id: @growth, allocation: 0.4 } ], places(@ada)
    end

    should "fill a full position anyway, and let Attention say it is overfilled" do
      move(@ada, from_unit_id: @payments, to_position_id: @position, allocation: 1)
      move(@cy, from_unit_id: "unassigned", to_position_id: @position, allocation: 1)

      assert_equal [ { position_id: @position, unit_id: @growth, allocation: 1.0 } ], places(@cy)
      items = call(Operations::TeamPlanning::Attention, plan_id: @plan_id, scenario_id: @q1)[:items]
      assert_equal [ [ @position, "Overfilled by 1 FTE" ] ], items.select { it[:facet] == "position" }.map { it.values_at(:subject_id, :reason) }
    end

    should "refuse a position the scenario lacks, and both destinations or neither" do
      assert_equal "This scenario has no such position",
                   refusal(from_unit_id: @payments, to_position_id: SecureRandom.uuid_v7, allocation: 1)
      assert_equal "Give to_unit_id or to_position_id, not both",
                   refusal(from_unit_id: @payments, to_unit_id: @growth, to_position_id: @position, allocation: 1)
      assert_equal "provide at least one of: to_unit_id, to_position_id", refusal(from_unit_id: @payments, allocation: 1)
      assert_equal [ @payments, @platform ].sort, places(@ada).pluck(:unit_id).sort
    end

    should "refuse a position whose unit the scenario retired" do
      call(Operations::TeamPlanning::RetireUnit, plan_id: @plan_id, scenario_id: @q1, unit_id: @growth)

      assert_equal "This scenario has no such position",
                   refusal(from_unit_id: @payments, to_position_id: @position, allocation: 1)
    end
  end
end
