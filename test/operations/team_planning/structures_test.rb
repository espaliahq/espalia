# frozen_string_literal: true

require "test_helper"

# A plan beneath a unit that declares its own structure (#494): the types it
# offers, where they sit, and what no longer fits.
class Operations::TeamPlanning::StructuresTest < ActiveSupport::TestCase
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant)
    @department, @squad = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    @engineering, @payments, @platform = Array.new(3) { SecureRandom.uuid_v7 }
    travel_to Time.utc(2026, 2, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
      structure.define_taxonomy([ { level_id: @department, name: "Department" },
                                  { level_id: @squad, name: "Squad", parent_level_ids: [ @department ], top: false } ],
                                effective_on: "2026-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: @department, effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: @squad, parent_id: @engineering, effective_on: "2026-01-01")
      structure.create_unit(@platform, "Platform", level_id: @squad, parent_id: @engineering, effective_on: "2026-01-01")
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
  end

  def call(operation, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person), params:)
    end
  end

  def set_unit(**params) = call(Operations::TeamPlanning::SetUnit, plan_id: @plan_id, **params)

  def refusal(**params) = assert_raises(Operations::Base::ParameterError) { set_unit(**params) }.message

  def misfits = call(Operations::TeamPlanning::Attention, plan_id: @plan_id)[:items].select { it[:check] == "misfits" }

  # Engineering's own structure: Group at its top, Pod beneath a Group. Its
  # squads become Groups.
  def declare
    levels = call(Operations::OrgGraph::DeclareStructure, unit_id: @engineering,
                                                          levels: [ { name: "Group" }, { name: "Pod", parent_names: %w[group pod], top: false } ],
                                                          conversion: { @squad => "Group" })[:levels]
    @group, @pod = levels.pluck(:level_id)
  end

  context "beneath a unit with its own structure" do
    setup { declare }

    should "create a unit of that structure's types, at its top beneath the declaring unit" do
      pod = set_unit(name: "Fraud", parent_id: @payments, level_id: @pod)
      group = set_unit(name: "Risk", parent_id: @engineering, level_id: @group)

      assert_equal [ @pod, @group ], [ pod[:level_id], group[:level_id] ]
      assert_equal "Pod can't sit at the top", refusal(name: "Fraud", parent_id: @engineering, level_id: @pod)
      assert_equal "Level is not a type of the structure this unit would sit in", refusal(name: "Ops", parent_id: @payments, level_id: @squad)
      assert_equal "Level is not in the taxonomy", refusal(name: "Ops", parent_id: @payments, level_id: SecureRandom.uuid_v7)
    end

    should "flag no Org Graph unit that holds a type of the structure it sits in" do
      assert_empty misfits
      set_unit(name: "Fraud", parent_id: @payments, level_id: @pod)

      assert_empty misfits
    end
  end

  context "with a unit the plan created before the declaration" do
    setup do
      @risk = set_unit(name: "Risk", parent_id: @engineering, level_id: @squad)[:unit_id]
      declare
    end

    should "mark it as holding a type of another structure, until it takes one of its own" do
      assert_equal [ [ @risk, "Doesn't fit this structure: its type belongs to another structure" ] ], misfits.map { it.values_at(:subject_id, :reason) }

      set_unit(unit_id: @risk, level_id: @group)
      assert_empty misfits
    end

    should "change its type only to one of the structure it sits in" do
      assert_equal "Level is not a type of the structure this unit would sit in", refusal(unit_id: @risk, level_id: @department)
    end
  end

  context "an Org Graph unit's type" do
    setup { declare }

    should "never change, in any structure" do
      assert_equal "A unit's level can't change: create a unit at the new level instead", refusal(unit_id: @payments, level_id: @pod)
    end
  end

  context "a move into another structure" do
    setup do
      declare
      @fraud = set_unit(name: "Fraud", parent_id: @payments, level_id: @pod)[:unit_id]
    end

    should "be refused for an Org Graph unit, and for a plan's unit that keeps its type" do
      crossing = "This move takes the unit into another structure, which a plan can't do yet. Move it in the Org Graph, " \
                 "or create a unit of that structure's type instead"
      assert_equal crossing, refusal(unit_id: @platform, top_level: true)
      assert_equal crossing, refusal(unit_id: @fraud, top_level: true)
    end

    should "take a plan's unit with nothing beneath it, given a type of the structure it lands in" do
      moved = set_unit(unit_id: @fraud, top_level: true, level_id: @department)

      assert_equal [ nil, @department ], moved.values_at(:parent_id, :level_id)
      assert_empty misfits
    end

    should "refuse a plan's unit with a unit beneath it, even with a new type" do
      set_unit(name: "Cards", parent_id: @fraud, level_id: @pod)

      assert_match "into another structure", refusal(unit_id: @fraud, top_level: true, level_id: @department)
    end

    should "never take an Org Graph unit, even with a new type" do
      assert_equal "A unit's level can't change: create a unit at the new level instead",
                   refusal(unit_id: @platform, top_level: true, level_id: @department)
    end
  end
end
