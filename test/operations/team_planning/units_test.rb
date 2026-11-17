# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::UnitsTest < ActiveSupport::TestCase
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant)
    @department, @squad = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    @engineering, @payments, @platform = Array.new(3) { SecureRandom.uuid_v7 }
    travel_to Time.utc(2026, 2, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
      structure.define_taxonomy([ { level_id: @department, name: "Department" }, { level_id: @squad, name: "Squad" } ],
                                effective_on: "2026-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: @department, effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: @squad, parent_id: @engineering, effective_on: "2026-01-01")
      structure.create_unit(@platform, "Platform", level_id: @squad, parent_id: @engineering, effective_on: "2026-01-01")
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @other_admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    @q1 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1",
                                                       ends_on: "2026-06-30")[:scenario_id]
    @lean = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, parent_id: @q1, relation: "instead",
                                                         name: "Lean Q1")[:scenario_id]
  end

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def write(operation, scenario_id = @q1, **params) = call(operation, plan_id: @plan_id, scenario_id:, **params)

  def refusal(operation, as: @admin, scenario_id: @q1, **params)
    assert_raises(Operations::Base::ParameterError) { call(operation, as:, plan_id: @plan_id, scenario_id:, **params) }.message
  end

  def units(scenario_id = @q1) = call(Operations::TeamPlanning::Units, plan_id: @plan_id, scenario_id:)

  def names(scenario_id = @q1, list = :units) = units(scenario_id)[list].pluck(:name)

  context "CoverableUnits" do
    should "list the whole organisation's live units in tree order, to anyone who may start a plan" do
      assert_equal [ [ "Engineering", nil, 0 ], [ "Payments", @engineering, 1 ], [ "Platform", @engineering, 1 ] ],
                   call(Operations::TeamPlanning::CoverableUnits)[:units].map { it.values_at(:name, :parent_id, :depth) }
    end

    should "refuse a member who may not start a plan, and a plan the caller doesn't edit" do
      member = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant)) }
      assert_raises(Pundit::NotAuthorizedError) { call(Operations::TeamPlanning::CoverableUnits, as: member) }
      call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: member.person.id, role: "viewer")
      assert_equal "No such plan", assert_raises(Operations::Base::ParameterError) {
        call(Operations::TeamPlanning::CoverableUnits, as: member, plan_id: @plan_id)
      }.message
      assert_equal 3, call(Operations::TeamPlanning::CoverableUnits, plan_id: @plan_id)[:units].size
    end
  end

  context "SetUnit" do
    should "create a unit with an id the plan mints, seen in its scenario and those after it only" do
      created = write(Operations::TeamPlanning::SetUnit, name: "  Risk  ", parent_id: @engineering, level_id: @squad)
      assert_equal({ plan_id: @plan_id, scenario_id: @q1, name: "Risk", parent_id: @engineering, level_id: @squad },
                   created.except(:unit_id))
      assert_match Operations::TeamPlanning::PlanWrite::UUID_RE, created[:unit_id]

      assert_equal %w[Engineering Payments Platform Risk], names
      assert_equal %w[Engineering Payments Platform Risk], names(@lean)
      assert_equal %w[Engineering Payments Platform], names(@plan_id)
    end

    should "rename a unit in place and move one, keeping what it leaves out" do
      write(Operations::TeamPlanning::SetUnit, unit_id: @payments, name: "Billing")
      write(Operations::TeamPlanning::SetUnit, @lean, unit_id: @platform, top_level: true)

      billing = units[:units].find { it[:unit_id] == @payments }
      assert_equal({ unit_id: @payments, name: "Billing", parent_id: @engineering, level_id: @squad }, billing)
      assert_nil units(@lean)[:units].find { it[:unit_id] == @platform }[:parent_id]
      assert_equal @engineering, units[:units].find { it[:unit_id] == @platform }[:parent_id]
    end

    should "refuse what the Org Graph would" do
      risk = write(Operations::TeamPlanning::SetUnit, name: "Risk", level_id: @squad)[:unit_id]
      {
        "provide at least one of: unit_id, level_id" => { name: "Risk" },
        "provide at least one of: unit_id, name" => { level_id: @squad },
        "Level is not in the taxonomy" => { name: "Risk", level_id: SecureRandom.uuid_v7 },
        "Squad can't sit under Squad" => { name: "Risk", level_id: @squad, parent_id: @payments },
        "The parent must be a live unit in this scenario" => { name: "Risk", level_id: @squad, parent_id: SecureRandom.uuid_v7 },
        "A unit's level can't change: create a unit at the new level instead" => { unit_id: risk, level_id: @department },
        "A unit can't move beneath itself or a unit below it" => { unit_id: @engineering, parent_id: @engineering },
        "Give parent_id or top_level, not both" => { unit_id: @payments, parent_id: @engineering, top_level: true },
        "There is no such unit in this scenario" => { unit_id: SecureRandom.uuid_v7, name: "Ghost" }
      }.each { |message, params| assert_equal message, refusal(Operations::TeamPlanning::SetUnit, **params) }
      assert_equal "There is no such unit in this scenario",
                   refusal(Operations::TeamPlanning::SetUnit, scenario_id: @plan_id, unit_id: risk, name: "Risk")
    end

    should "place units where the unit types' stated rules let them sit" do
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
                                         .set_kind_parents(@squad, parent_ids: [ @department, @squad ], top: false, effective_on: "2026-02-01")
      end

      assert_equal @payments, write(Operations::TeamPlanning::SetUnit, name: "Risk", level_id: @squad, parent_id: @payments)[:parent_id]
      assert_equal "Squad can't sit at the top", refusal(Operations::TeamPlanning::SetUnit, name: "Lone", level_id: @squad, top_level: true)
      sales = write(Operations::TeamPlanning::SetUnit, name: "Sales", level_id: @department)[:unit_id]
      assert_equal "Department can't sit under Squad", refusal(Operations::TeamPlanning::SetUnit, unit_id: sales, parent_id: @payments)
    end

    should "refuse a parent outside a scoped plan's units as missing, never naming its type" do
      call(Operations::TeamPlanning::SetPlanScope, plan_id: @plan_id, unit_ids: [ @payments ])

      [ @platform, @engineering ].each do |outside|
        assert_equal "The parent must be a live unit in this scenario",
                     refusal(Operations::TeamPlanning::SetUnit, name: "Risk", level_id: @squad, parent_id: outside)
      end
      assert_equal "Department can't sit under Squad",
                   refusal(Operations::TeamPlanning::SetUnit, name: "Sales", level_id: @department, parent_id: @payments)
      assert_equal [ "Payments" ], names
    end

    should "rename a unit whose level has left the taxonomy, and refuse to place a unit beneath it" do
      guild_level = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: SYSTEM).add_level(guild_level, "Guild", effective_on: "2026-01-01")
      end
      guild = write(Operations::TeamPlanning::SetUnit, name: "Guild", level_id: guild_level)[:unit_id]
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: SYSTEM).remove_level(guild_level, effective_on: "2026-01-02")
      end

      assert_equal "Crafts", write(Operations::TeamPlanning::SetUnit, unit_id: guild, name: "Crafts")[:name]
      assert_equal "Level is no longer in the taxonomy, so the unit can't be placed",
                   refusal(Operations::TeamPlanning::SetUnit, name: "Risk", level_id: @squad, parent_id: guild)
    end
  end

  context "RetireUnit" do
    should "retire a leaf, bring it back by setting it again, and refuse a unit with live sub-units" do
      assert_equal "Move or retire its sub-units first", refusal(Operations::TeamPlanning::RetireUnit, unit_id: @engineering)

      write(Operations::TeamPlanning::RetireUnit, unit_id: @platform)
      assert_equal %w[Engineering Payments], names
      assert_equal %w[Platform], names(@q1, :retired_units)
      assert_equal "There is no such live unit in this scenario", refusal(Operations::TeamPlanning::RetireUnit, unit_id: @platform)

      write(Operations::TeamPlanning::SetUnit, @lean, unit_id: @platform)
      assert_equal %w[Engineering Payments Platform], names(@lean)
      assert_empty units(@lean)[:retired_units]
    end

    should "bring a unit back only beneath a live parent" do
      [ @payments, @platform, @engineering ].each { write(Operations::TeamPlanning::RetireUnit, unit_id: it) }

      assert_equal "The parent must be a live unit in this scenario",
                   refusal(Operations::TeamPlanning::SetUnit, unit_id: @payments)
      write(Operations::TeamPlanning::SetUnit, unit_id: @payments, top_level: true)
      assert_equal %w[Payments], names
    end

    should "retire a unit the plan created, and one it renamed, as each stood" do
      risk = write(Operations::TeamPlanning::SetUnit, name: "Risk", parent_id: @engineering, level_id: @squad)[:unit_id]
      write(Operations::TeamPlanning::SetUnit, unit_id: @payments, name: "Billing")
      write(Operations::TeamPlanning::RetireUnit, unit_id: risk)
      write(Operations::TeamPlanning::SetUnitSuccession, predecessor_ids: [ @payments ], successor_ids: [ @platform ])

      assert_equal %w[Billing Risk], names(@q1, :retired_units).sort
      assert_equal %w[Engineering Platform], names
    end
  end

  context "SetUnitSuccession" do
    should "split a unit, retiring it in the same write" do
      card, wallet = %w[Cards Wallets].map { write(Operations::TeamPlanning::SetUnit, name: it, parent_id: @engineering, level_id: @squad)[:unit_id] }
      result = write(Operations::TeamPlanning::SetUnitSuccession, predecessor_ids: [ @payments ], successor_ids: [ wallet, card ])

      assert_equal [ @payments ], result[:retired_ids]
      assert_equal [ card, wallet ].sort, result[:successor_ids]
      assert_equal %w[Cards Engineering Platform Wallets], names
      assert_equal [ { succession_id: result[:succession_id], predecessor_ids: [ @payments ], successor_ids: [ card, wallet ].sort } ],
                   units[:successions]
      assert_empty units(@plan_id)[:successions]
    end

    should "merge two units into one and restate the succession" do
      core = write(Operations::TeamPlanning::SetUnit, name: "Core", parent_id: @engineering, level_id: @squad)[:unit_id]
      merged = write(Operations::TeamPlanning::SetUnitSuccession, predecessor_ids: [ @payments, @platform ], successor_ids: [ core ])
      assert_equal %w[Core Engineering], names

      write(Operations::TeamPlanning::SetUnitSuccession, succession_id: merged[:succession_id], predecessor_ids: [ @payments ],
                                                         successor_ids: [ core ])
      assert_equal [ [ @payments ] ], units[:successions].pluck(:predecessor_ids)
    end

    should "refuse a succession that can't hold" do
      core = write(Operations::TeamPlanning::SetUnit, name: "Core", parent_id: @engineering, level_id: @squad)[:unit_id]
      write(Operations::TeamPlanning::SetUnitSuccession, predecessor_ids: [ @payments ], successor_ids: [ core ])
      {
        "A unit can't succeed itself" => { predecessor_ids: [ @platform ], successor_ids: [ @platform ] },
        "A successor must be live" => { predecessor_ids: [ @platform ], successor_ids: [ @payments ] }
      }.each { |message, params| assert_equal message, refusal(Operations::TeamPlanning::SetUnitSuccession, **params) }
      write(Operations::TeamPlanning::SetUnit, unit_id: @payments)
      assert_equal "A unit can't come to precede itself",
                   refusal(Operations::TeamPlanning::SetUnitSuccession, predecessor_ids: [ core ], successor_ids: [ @payments ])
      assert_equal "Move or retire the sub-units of each predecessor first",
                   refusal(Operations::TeamPlanning::SetUnitSuccession, predecessor_ids: [ @engineering ], successor_ids: [ core ])
      assert_equal "predecessor_ids must hold unit ids",
                   refusal(Operations::TeamPlanning::SetUnitSuccession, predecessor_ids: [ "payments" ], successor_ids: [ core ])
      assert_equal "There is no such succession in this scenario",
                   refusal(Operations::TeamPlanning::SetUnitSuccession, succession_id: SecureRandom.uuid_v7,
                                                                        predecessor_ids: [ @platform ], successor_ids: [ core ])
    end
  end

  should "read as missing to an admin outside the plan" do
    [ [ Operations::TeamPlanning::Units, {} ],
      [ Operations::TeamPlanning::SetUnit, { name: "Risk", level_id: @squad } ],
      [ Operations::TeamPlanning::RetireUnit, { unit_id: @platform } ],
      [ Operations::TeamPlanning::SetUnitSuccession, { predecessor_ids: [ @payments ], successor_ids: [ @platform ] } ] ]
      .each { |operation, params| assert_equal "No such plan", refusal(operation, as: @other_admin, **params), operation.name }
  end

  should "keep one tenant's plan out of another's reach" do
    elsewhere = create(:tenant)
    stranger = ActsAsTenant.with_tenant(elsewhere) do
      create(:tenant_user, tenant: elsewhere, role: :admin, person: create(:person, tenant: elsewhere))
    end
    error = assert_raises(Operations::Base::ParameterError) do
      ActsAsTenant.with_tenant(elsewhere) do
        Operations::TeamPlanning::Units.call(context: AuthorizationContext.new(user: stranger.user, tenant_user: stranger,
                                                                               person: stranger.person),
                                             params: { plan_id: @plan_id })
      end
    end
    assert_equal "No such plan", error.message
  end
end
