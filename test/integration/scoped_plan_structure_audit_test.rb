# frozen_string_literal: true

require "test_helper"

# A plan scoped beneath a unit with its own structure reads that structure's
# types, and nothing of the unit that declared it or of another branch's
# structure ([#494](https://github.com/espaliahq/espalia/issues/494)). Every
# read that takes a plan_id is walked, so a new one joins with no edit; one
# that needs a parameter this file has no value for fails until it gets one. The plan is walked open and again once its step
# closes, and every read must reach a payload in one of the two.
class ScopedPlanStructureAuditTest < ActiveSupport::TestCase
  SYSTEM = OrgGraph::Authorization::SYSTEM
  KNOWN = %i[plan_id scenario_id unit_id ends_on rule].freeze
  # The scope picker lists every live unit an editor may cover, by design
  # ([#338](https://github.com/espaliahq/espalia/issues/338)), so only its
  # types are held to the plan's scope.
  WHOLE_ORGANISATION = %w[team_planning_coverable_units].freeze

  setup do
    @tenant = create(:tenant)
    @department, @squad = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    @engineering, @payments, @sales, @emea = Array.new(4) { SecureRandom.uuid_v7 }
    travel_to Time.utc(2026, 1, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
      structure.define_taxonomy([ { level_id: @department, name: "Department" },
                                  { level_id: @squad, name: "Squad", parent_level_ids: [ @department ], top: false } ],
                                effective_on: "2026-01-01")
      structure.set_kind_parents(@squad, parent_ids: [ @department, @squad ], top: false, effective_on: "2026-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: @department, effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: @squad, parent_id: @engineering, effective_on: "2026-01-01")
      structure.create_unit(@sales, "Sales", level_id: @department, effective_on: "2026-01-01")
      structure.create_unit(@emea, "Sales EMEA", level_id: @squad, parent_id: @sales, effective_on: "2026-01-01")
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    end
    travel_to Time.utc(2026, 2, 1, 9) # a base before today, so a rebase can be previewed
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Payments next year", base_on: "2026-01-15")[:plan_id]
    call(Operations::TeamPlanning::SetPlanScope, plan_id: @plan_id, unit_ids: [ @payments ])
    @unit_id = call(Operations::TeamPlanning::SetUnit, plan_id: @plan_id, name: "Risk", parent_id: @payments, level_id: @squad)[:unit_id]
    @scenario_id = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1",
                                                                ends_on: "2026-06-30")[:scenario_id]

    @group, @pod = declare(@engineering, %w[Group Pod])
    @territory, @region = declare(@sales, %w[Territory Region])
    call(Operations::TeamPlanning::SetUnit, plan_id: @plan_id, name: "Fraud", parent_id: @payments, level_id: @pod)
  end

  def call(operation, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person), params:)
    end
  end

  # Top type, then one that nests beneath it or itself; the unit's squads take the top one.
  def declare(unit_id, (top, nested))
    levels = [ { name: top }, { name: nested, parent_names: [ top.downcase, nested.downcase ], top: false } ]
    call(Operations::OrgGraph::DeclareStructure, unit_id:, levels:, conversion: { @squad => top })[:levels].pluck(:level_id)
  end

  def plan_reads
    Operations::Registry.all.select { it.category == :read && it.parameters.key?(:plan_id) }
  end

  def params_for(operation)
    names = operation.parameters.keys
    missing = operation.parameters.values.select(&:required).map(&:name) - KNOWN
    assert_empty missing, "#{Operations::Registry.tool_name_for(operation)} needs a value this audit lacks; add it to KNOWN and #params_for"

    values = { plan_id: @plan_id, scenario_id: @scenario_id, unit_id: @payments,
               ends_on: "2026-09-30", rule: TeamPlanning::RuleKinds.all.first.rule_name }
    values.slice(*names)
  end

  # Q1 ends, and closes: the state team_planning_step_outcome needs, and one
  # the reads that preview a change to the step refuse.
  def close_q1
    travel_to Time.utc(2026, 7, 1, 9)
    call(Operations::TeamPlanning::CloseStep, plan_id: @plan_id, scenario_id: @scenario_id)
  end

  # @param refusals [Hash{String, Symbol => String}] tool, or :all, => the start of the one refusal it may give here
  # @return [Hash{String => String, nil}] tool => its payload as JSON, nil where it refused as allowed
  def walk(refusals = {})
    plan_reads.to_h do |operation|
      tool = Operations::Registry.tool_name_for(operation)
      [ tool, call(operation, **params_for(operation)).as_json.to_json ]
    rescue Operations::Base::ParameterError => e
      allowed = refusals[tool] || refusals[:all]
      flunk "#{tool} refused the audit's plan: #{e.message}" unless allowed && e.message.start_with?(allowed)
      [ tool, nil ]
    end
  end

  # Each read reaches a payload in one of the plan's two states, or the walk fails.
  def payloads
    open = walk("team_planning_step_outcome" => "This step isn't closed")
    close_q1
    closed = walk(all: "This step is closed", "team_planning_rebase_preview" => "This plan has a closed step")
    open.merge(closed) { |_tool, before, after| [ before, after ].compact.join.presence }.tap do |all|
      assert_empty all.select { |_tool, json| json.nil? }.keys, "a plan read reached no payload in either state"
    end
  end

  should "walk every plan read" do
    assert_operator plan_reads.size, :>=, 25
    assert_includes plan_reads.map { Operations::Registry.tool_name_for(it) }, "team_planning_units"
  end

  should "show a scoped plan nothing of the unit above it or another branch's structure" do
    payloads = self.payloads
    units = { "Engineering's id" => @engineering, "Engineering" => "Engineering",
              "Sales' id" => @sales, "Sales" => "Sales", "Sales EMEA's id" => @emea }
    types = { "Territory's id" => @territory, "Region's id" => @region, "Territory" => "Territory", "Region" => "Region" }

    leaks = payloads.flat_map do |tool, json|
      outside = WHOLE_ORGANISATION.include?(tool) ? types : units.merge(types)
      outside.select { |_what, value| json.include?(value) }.keys.map { "#{tool} shows #{it}" }
    end
    assert_empty leaks
    assert_includes payloads.fetch("team_planning_units"), @pod, "the audit's plan holds no unit of the structure above it"
    assert_includes payloads.fetch("team_planning_attention"), "Doesn't fit this structure", "the audit's plan has no misfit"
  end

  should "judge the Org Graph's units by the type a declaration gave them after the plan's base" do
    misfits = call(Operations::TeamPlanning::Attention, plan_id: @plan_id)[:items].select { it[:check] == "misfits" }

    assert_equal [ @unit_id ], misfits.pluck(:subject_id), "only Risk, the plan's Squad, holds a type of another structure"
    units = call(Operations::TeamPlanning::Units, plan_id: @plan_id)[:units].find { it[:unit_id] == @payments }
    mapped = call(Operations::TeamPlanning::ScenarioMap, plan_id: @plan_id, scenario_id: @scenario_id)[:units].find { it[:id] == @payments }
    assert_equal [ @group, @group ], [ units[:level_id], mapped[:level_id] ], "the plan reads Payments as a Group, as its checks do"
  end

  should "refuse a parent outside the plan alike, whatever structure it declares or sits in" do
    refusals = [ @engineering, @sales, @emea ].flat_map do |parent_id|
      [ { name: "Ops", parent_id:, level_id: @pod }, { name: "Ops", parent_id:, level_id: @territory },
        { name: "Ops", parent_id:, level_id: @squad }, { unit_id: @unit_id, parent_id: },
        { unit_id: @unit_id, parent_id:, level_id: @territory }, { unit_id: @unit_id, parent_id:, level_id: @pod } ].map do |params|
        assert_raises(Operations::Base::ParameterError) { call(Operations::TeamPlanning::SetUnit, plan_id: @plan_id, **params) }.message
      end
    end

    assert_equal [ "The parent must be a live unit in this scenario" ], refusals.uniq
  end

  # Engineering's declaration straddles the scope: Payments is covered,
  # Engineering isn't. Sales' lies wholly outside. Payments then declares one
  # of its own, inside, over Cards.
  context "a plan whose drift holds structure changes" do
    setup do
      @cards = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: SYSTEM).create_unit(@cards, "Cards", level_id: @pod, parent_id: @payments, effective_on: "2026-02-01")
      end
      travel_to Time.utc(2026, 2, 3, 9)
      call(Operations::OrgGraph::DeclareStructure, unit_id: @payments, levels: [ { name: "Lane" } ], conversion: { @pod => "Lane" })
    end

    should "read each as one change, naming only what the plan covers, in every read that lists drift" do
      payloads = walk("team_planning_step_outcome" => "This step isn't closed").compact
      ungrouped = payloads.select { |_tool, json| json.include?('"kind":"unit_kind_changed"') }.keys
      grouping = payloads.select { |_tool, json| json.include?('"kind":"structure_declared"') }

      assert_empty ungrouped, "a read lists a structure's type changes one unit at a time"
      assert_includes grouping.keys, "team_planning_drift"
      assert_includes grouping.keys, "team_planning_rebase_preview"
      grouping.each do |tool, json|
        items = JSON.parse(json).then { it["drift"] || it }.fetch("changes").select { it["kind"] == "structure_declared" }
        assert_equal [ [ nil, [ @payments ], 1, [ "unit_id" ] ], [ @payments, [ @cards ], 1, [] ] ],
                     items.map { it.values_at("unit_id", "unit_ids", "count", "outside") }, "#{tool} groups a structure's type changes"
      end
    end
  end

  context "a plan whose drift holds a move between structures" do
    setup do
      travel_to Time.utc(2026, 2, 3, 9)
      call(Operations::OrgGraph::MoveUnit, unit_id: @payments, parent_id: @sales, conversion: { @group => @territory })
      call(Operations::OrgGraph::MoveUnit, unit_id: @emea, parent_id: @engineering, conversion: { @territory => @group })
    end

    should "read the move as one change, hiding both structures it crossed, and nothing of one wholly outside the plan" do
      payloads = walk("team_planning_step_outcome" => "This step isn't closed").compact
      parted = payloads.select { |_tool, json| json.include?('"kind":"unit_kind_changed"') || json.include?('"kind":"unit_moved"') }.keys
      crossing = payloads.select { |_tool, json| json.include?('"kind":"moved_between_structures"') }

      assert_empty parted, "a read lists a move between structures in parts"
      assert_includes crossing.keys, "team_planning_drift"
      assert_includes crossing.keys, "team_planning_rebase_preview"
      crossing.each do |tool, json|
        items = JSON.parse(json).then { it["drift"] || it }.fetch("changes").select { it["kind"] == "moved_between_structures" }
        assert_equal [ [ @payments, [ @payments ], 1, %w[before after], nil, nil ] ],
                     items.map { [ *it.values_at("unit_id", "unit_ids", "count", "outside"), *[ it["before"], it["after"] ].pluck("structure_unit_id") ] },
                     "#{tool} folds Payments' move into one change"
      end
    end
  end

  context "a plan whose drift holds a move between structures by a unit above it" do
    setup do
      @core, @ledger = SecureRandom.uuid_v7, SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
        structure.create_unit(@core, "Mesh Core", level_id: @group, parent_id: @engineering, effective_on: "2026-02-01")
        structure.create_unit(@ledger, "Ledger", level_id: @pod, parent_id: @core, effective_on: "2026-02-01")
      end
      call(Operations::TeamPlanning::SetPlanScope, plan_id: @plan_id, unit_ids: [ @payments, @ledger ])
      travel_to Time.utc(2026, 2, 3, 9)
      call(Operations::OrgGraph::MoveUnit, unit_id: @core, parent_id: @sales, conversion: { @group => @territory, @pod => @region })
    end

    should "count the unit it carried, and name neither the mover nor either structure" do
      crossing = walk("team_planning_step_outcome" => "This step isn't closed").compact
                 .select { |_tool, json| json.include?('"kind":"moved_between_structures"') }
      assert_includes crossing.keys, "team_planning_drift"

      crossing.each do |tool, json|
        drift = JSON.parse(json).then { it["drift"] || it }
        items = drift.fetch("changes").select { it["kind"] == "moved_between_structures" }
        assert_equal [ [ nil, [ @ledger ], 1, %w[unit_id before after] ] ], items.map { it.values_at("unit_id", "unit_ids", "count", "outside") }, tool
        shown = [ items, drift.fetch("names") ].to_json
        leaks = { "Mesh Core's id" => @core, "Mesh Core" => "Mesh Core", "Engineering's id" => @engineering,
                  "Engineering" => "Engineering", "Sales' id" => @sales, "Sales" => "Sales" }.select { |_what, value| shown.include?(value) }.keys
        assert_empty leaks, "#{tool} names what lies above the plan"
      end
    end
  end

  context "an archived plan with a unit of a declared type" do
    setup { call(Operations::TeamPlanning::ArchivePlan, plan_id: @plan_id) }

    should "still read once the structure its units sat in is withdrawn" do
      call(Operations::OrgGraph::WithdrawStructure, unit_id: @engineering, conversion: { @group => @squad })

      assert_equal plan_reads.size, walk(all: "This plan is archived", "team_planning_step_outcome" => "This step isn't closed").size
    end

    should "still read once that type is removed" do
      call(Operations::OrgGraph::RemoveLevel, level_id: @pod, structure_unit_id: @engineering)

      assert_equal plan_reads.size, walk(all: "This plan is archived", "team_planning_step_outcome" => "This step isn't closed").size
    end
  end
end
