# frozen_string_literal: true

require "test_helper"

# The settings panel offers Remove on a unit type exactly when RemoveLevel
# would take it today ([#494](https://github.com/espaliahq/espalia/issues/494)).
class Operations::OrgGraph::RemovalParityTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    @structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    as_tenant do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @guild = SecureRandom.uuid_v7
      @structure.add_level(@guild, "Guild", effective_on: "2026-01-01")
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def call(operation, **params)
    as_tenant do
      operation.call(context: AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person), params:)
    end
  end

  # Every type the panel lists, with whether it offers Remove and whether
  # RemoveLevel, tried and rolled back, takes it.
  def offered_and_taken
    sources = call(Operations::OrgGraph::Sources)
    structures = [ [ nil, sources[:levels] ] ] + sources[:structures].map { [ it[:unit_id], it[:levels] ] }
    structures.flat_map do |unit_id, levels|
      levels.map { |level| [ level[:name], level[:removable], taken?(level[:id], unit_id) ] }
    end
  end

  def taken?(level_id, structure_unit_id)
    ActiveRecord::Base.transaction(requires_new: true) do
      call(Operations::OrgGraph::RemoveLevel, level_id:, structure_unit_id:)
      raise ActiveRecord::Rollback
    end
    true
  rescue Operations::Base::ParameterError
    false
  end

  def assert_parity(expected)
    rows = offered_and_taken
    rows.each { |name, offered, taken| assert_equal taken, offered, "#{name}: Remove offered #{offered}, RemoveLevel took it #{taken}" }
    expected.each { |name, taken| assert_equal taken, rows.find { it.first == name }.last, "#{name} taken" }
  end

  should "offer a type a unit held until it retired" do
    as_tenant do
      unit = SecureRandom.uuid_v7
      @structure.create_unit(unit, "Atlas", level_id: @guild, effective_on: "2026-01-01")
      @structure.retire_unit(unit, effective_on: "2026-02-01")
    end

    assert_parity("Guild" => true, "Team" => false, "Squad" => false, "Department" => false)
  end

  should "offer a type a unit changed away from" do
    as_tenant do
      unit = SecureRandom.uuid_v7
      @structure.create_unit(unit, "Atlas", level_id: @guild, effective_on: "2026-01-01")
      @structure.change_unit_kind(unit, @org[:team], effective_on: "2026-03-01")
    end

    assert_parity("Guild" => true)
  end

  should "keep a type a unit holds from a later date" do
    as_tenant { @structure.create_unit(SecureRandom.uuid_v7, "Atlas", level_id: @guild, effective_on: Date.current + 30) }

    assert_parity("Guild" => false)
  end

  should "keep a type another can sit only under" do
    as_tenant do
      chapter = SecureRandom.uuid_v7
      @structure.add_level(chapter, "Chapter", effective_on: Date.current)
      @structure.set_kind_parents(chapter, parent_ids: [ @guild ], top: false, effective_on: Date.current)
    end

    assert_parity("Guild" => false, "Chapter" => true)
  end

  should "keep a type a live plan places a unit at" do
    plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: Date.current.iso8601)[:plan_id]
    scenario_id = call(Operations::TeamPlanning::ForkScenario, plan_id:, relation: "then", name: "Q1",
                                                               ends_on: (Date.current + 90).iso8601)[:scenario_id]
    call(Operations::TeamPlanning::SetUnit, plan_id:, scenario_id:, name: "Ledger", top_level: true, level_id: @guild)

    assert_parity("Guild" => false)
  end

  should "judge a unit's own structure by its own units" do
    levels = call(Operations::OrgGraph::DeclareStructure, unit_id: @org[:payments],
                                                          levels: [ { name: "Lane" }, { name: "Stream" } ])[:levels]
    lane = levels.find { it[:name] == "Lane" }[:level_id]
    as_tenant do
      @structure.create_unit(SecureRandom.uuid_v7, "Ledger", level_id: lane, parent_id: @org[:payments], effective_on: Date.current)
    end

    assert_parity("Lane" => false, "Stream" => true)
  end
end
