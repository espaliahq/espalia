# frozen_string_literal: true

require "test_helper"

class TeamPlanning::CapacityTest < ActiveSupport::TestCase
  class Hiring < TeamPlanning::ForecastKind
    def self.rule_name = "test_capacity_hiring"
    def self.description = "One forecast hire in each unit"
    def self.default = { "hires" => "0" }

    def self.forecast(frame)
      frame.map.units.filter_map do |unit|
        hires = Rational(frame.rule_at(unit.id)["hires"])
        frame.row(unit_id: unit.id, headcount: hires, capacity: { "per_fte" => hires }) if hires.positive?
      end
    end
  end
  ESPALIA = { provider: "espalia", effective_on: "2026-02-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  BASE_ON = Date.new(2026, 3, 2)

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    people = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    departments = SecureRandom.uuid_v7
    @engineering, @payments = Array.new(2) { SecureRandom.uuid_v7 }

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @engineering_family = create(:framework_role_family, name: "Engineering")
      @engineer = create(:framework_role, code: "E", name: "Software Engineer", role_family_id: @engineering_family.role_family_id)
      @e5 = create(:framework_level, role_id: @engineer.role_id, ordinal: 5, title: "Senior SWE")
      @manager = create(:framework_role, code: "EM", name: "Engineering Manager", track: "management",
                                         role_family_id: @engineering_family.role_family_id)
      @em5 = create(:framework_level, role_id: @manager.role_id, ordinal: 5, title: "Manager")

      structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: "2026-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: departments, effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: departments, effective_on: "2026-01-01")

      @ada, @brook, @cy, @dee = %w[Ada Brook Cy Dee].map { create(:person, tenant: @tenant, name: "#{it} Quill") }
      people.record_person(@ada.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0)
      people.record_person(@brook.id, **ESPALIA, employment_status: "employed", title: "Engineering Manager", level: "5", fte: 0.8)
      people.record_person(@cy.id, **ESPALIA, employment_status: "employed", title: "Juggler", level: "5", fte: 1.0)
      people.record_person(@dee.id, **ESPALIA, employment_status: "employed", title: "Software Engineer", level: "5")
      people.set_membership(@ada.id, @engineering, **ESPALIA, allocation: 1.0)
      people.set_membership(@brook.id, @engineering, **ESPALIA, allocation: 0.5)
      people.set_membership(@brook.id, @payments, **ESPALIA, allocation: 0.5)
      people.set_membership(@cy.id, @payments, **ESPALIA, allocation: 1.0)

      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: BASE_ON)
    end
  end

  def as_tenant(tenant = @tenant, &) = ActsAsTenant.with_tenant(tenant, &)

  def context_for(tenant_user) = AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)

  def handler = TeamPlanning::CommandHandler.new(actor: context_for(@planner))

  def per_fte = { model: "per_fte" }

  def choose(subject_id: @plan_id, families: {}, roles: {})
    as_tenant do
      handler.set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id: @plan_id, subject_id:,
                                                                  end_state: { rule: "capacity_model", value: { families:, roles: } })
    end
  end

  def open_position(role: @engineer, level: @e5, unit_id: @payments, fte: 1)
    as_tenant do
      context = context_for(@planner)
      Operations::TeamPlanning::SetPosition.call(context:, params: { plan_id: @plan_id, scenario_id: @plan_id, role_id: role.role_id,
                                                                     level_id: level.level_id, unit_id:, fte:, basis: "new" })[:position_id]
    end
  end

  def operation(operation, **params)
    as_tenant { operation.call(context: context_for(@planner), params: { plan_id: @plan_id, scenario_id: @plan_id, **params }) }
  end

  def place_in(person, placements) = operation(Operations::TeamPlanning::SetAssignment, person_id: person.id, placements:)

  def capacity(as: @planner)
    as_tenant { TeamPlanning::Capacity.new(context: context_for(as), plan: TeamPlanningPlan.find(@plan_id), scenario_id: @plan_id).call }
  end

  def seat(report, id) = report.seats.find { it.seat.id == id }

  def split(scenario_id)
    as_tenant { TeamPlanning::Capacity.split(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id:) }
  end

  context "actual, planned and forecast" do
    setup do
      choose(families: { @engineering_family.role_family_id => per_fte })
      @year = operation(Operations::TeamPlanning::ForkScenario, scenario_id: nil, relation: "then", name: "2026", ends_on: "2026-12-31")[:scenario_id]
      operation(Operations::TeamPlanning::SetAssignment, scenario_id: @year, person_id: @ada.id,
                                                         placements: [ { unit_id: @payments, allocation: 1 } ])
    end

    should "count someone moved as actual in the old unit, negative planned there and positive planned in the new" do
      result = split(@year)

      engineering = result.parts(@engineering)
      assert_equal [ Rational(7, 5), Rational(-1), Rational(2, 5) ],
                   [ engineering.actual["per_fte"], engineering.planned["per_fte"], engineering.total["per_fte"] ]
      assert_equal 1r, result.parts(@payments).planned["per_fte"]
      assert_equal 0r, result.parts.planned["per_fte"]
    end

    should "add the parts up to the total exactly, with the forecast's rows in their own unit" do
      TeamPlanning::RuleKinds.register(Hiring)
      operation(Operations::TeamPlanning::SetRule, scenario_id: @year, unit_id: @payments, rule: "test_capacity_hiring", value: { hires: "2" })
      result = split(@year)

      [ nil, @engineering, @payments ].each do |unit_id|
        parts = result.parts(unit_id)
        added = TeamPlanning::Capacity.add([ parts.actual, parts.planned, parts.forecast ])
        assert_equal parts.total.fetch("per_fte"), added.fetch("per_fte"), "unit #{unit_id.inspect}"
      end
      assert_equal [ {}, { "per_fte" => 2r } ], [ result.parts(@engineering).forecast, result.parts(@payments).forecast ]
      assert_equal result.report.totals["per_fte"] + 2, result.parts.total["per_fte"]
    ensure
      TeamPlanning::RuleKinds.unregister(Hiring)
    end

    should "read the Org Graph baseline once for the scenario and the baseline alike" do
      reads = 0
      as_of = OrgGraph::AsOf.method(:new)
      OrgGraph::AsOf.stub(:new, ->(**args) { reads += 1; as_of.call(**args) }) { split(@year) }

      assert_equal 1, reads
    end

    should "make Today all actual, with no forecast and the plain totals" do
      result = split(@plan_id)

      assert_nil result.baseline
      assert_equal [ result.report.totals, {}, {} ], [ result.parts.actual, result.parts.planned, result.parts.forecast ]
    end
  end

  should "count nothing and leave every seat unclassified until a model is chosen" do
    report = capacity

    assert_empty report.totals
    assert_equal [ "no_model" ], seat(report, @ada.id).places.map(&:reason)
  end

  should "price each seat by its family's model, a person in two units split by allocation, exactly" do
    choose(families: { @engineering_family.role_family_id => per_fte })
    report = capacity

    assert_equal({ "per_fte" => Rational(14, 5) }, report.totals)
    assert_equal({ "per_fte" => Rational(7, 5) }, report.units[@engineering])
    assert_equal({ "per_fte" => Rational(2, 5) }, report.units[@payments])

    brook = seat(report, @brook.id)
    assert_equal [ Rational(2, 5), Rational(2, 5) ], brook.places.map { it.figure.amount }
    assert_equal [ "family" ], brook.places.map(&:chosen_for).uniq
    assert_equal [ @manager.role_id, @em5.level_id ], [ brook.places.first.place.role_id, brook.places.first.place.level_id ]
    assert_kind_of Rational, report.totals["per_fte"]
  end

  should "let a role's choice beat its family's, and say which chose" do
    choose(families: { @engineering_family.role_family_id => per_fte }, roles: { @manager.role_id => per_fte })

    assert_equal %w[family role], [ seat(capacity, @ada.id), seat(capacity, @brook.id) ].map { it.places.first.chosen_for }
  end

  should "reach a unit's choice down to its seats there and not to its siblings" do
    choose(subject_id: @engineering, families: { @engineering_family.role_family_id => per_fte })
    report = capacity

    assert_equal({ "per_fte" => Rational(7, 5) }, report.totals)
    assert_equal [ nil, "no_model" ], seat(report, @brook.id).places.sort_by { it.unit_id == @engineering ? 0 : 1 }.map(&:reason)
  end

  should "price a vacant position like a filled seat, even in a unit off the map" do
    choose(families: { @engineering_family.role_family_id => per_fte })
    off_map = SecureRandom.uuid_v7
    on_map = open_position(fte: 0.5)
    elsewhere = open_position(unit_id: off_map)
    report = capacity

    assert_equal Rational(1, 2), seat(report, on_map).places.first.figure.amount
    assert_equal "position", seat(report, on_map).seat.kind
    assert_equal 1r, seat(report, elsewhere).places.first.figure.amount
    assert_equal({ "per_fte" => Rational(43, 10) }, report.totals)
  end

  should "price a place in a position as the position's work, and the position for only what its people leave open" do
    choose(families: { @engineering_family.role_family_id => per_fte })
    position_id = open_position(fte: 1)
    place_in(@cy, [ { position_id:, allocation: 0.5 }, { unit_id: @payments, allocation: 0.5 } ])
    report = capacity

    cy = seat(report, @cy.id)
    in_position, in_unit = cy.places.partition { it.place.position_id }.map(&:first)
    assert_equal [ @engineer.role_id, @e5.level_id, @payments ], [ in_position.place.role_id, in_position.place.level_id, in_position.unit_id ]
    assert_equal Rational(1, 2), in_position.figure.amount
    assert_equal "unmapped_title", in_unit.reason
    assert_equal Rational(1, 2), seat(report, position_id).seat.fte
  end

  should "leave a position filled to its FTE out of the seats, so it is never counted twice" do
    choose(families: { @engineering_family.role_family_id => per_fte })
    position_id = open_position(fte: 1)
    place_in(@cy, [ { position_id:, allocation: 1 } ])

    assert_nil seat(capacity, position_id)
    assert_equal({ "per_fte" => Rational(19, 5) }, capacity.totals)
  end

  should "list a place in a closed position as unclassified" do
    choose(families: { @engineering_family.role_family_id => per_fte })
    position_id = open_position
    place_in(@cy, [ { position_id:, allocation: 1 } ])
    operation(Operations::TeamPlanning::ClosePosition, position_id:)

    assert_equal [ [ nil, "closed_position" ] ], seat(capacity, @cy.id).places.map { [ it.unit_id, it.reason ] }
  end

  should "share what a person's recorded allocations leave among the places the HRIS gave none, and say so" do
    choose(families: { @engineering_family.role_family_id => per_fte })
    as_tenant do
      people = OrgGraph::CommandHandler.new(actor: SYSTEM)
      people.set_membership(@dee.id, @engineering, **ESPALIA, allocation: 0.4)
      people.set_membership(@dee.id, @payments, **ESPALIA)
    end
    dee = seat(capacity, @dee.id)

    assert_equal [ Rational(2, 5), Rational(3, 5) ], dee.places.sort_by { it.unit_id == @engineering ? 0 : 1 }.map { it.place.allocation }
    unknown = dee.places.find { it.unit_id == @payments }
    assert_not unknown.place.allocation_known
    assert_equal "Share not recorded, split from what the other places leave", unknown.figure.working.second.label
    assert_equal 1r, dee.places.sum { it.figure.amount }
  end

  should "count a place in a unit gone from the map for the plan, under no unit" do
    choose(families: { @engineering_family.role_family_id => per_fte })
    gone = SecureRandom.uuid_v7
    open_position(unit_id: gone)

    assert_nil capacity.units[gone]
    assert_equal({ "per_fte" => Rational(19, 5) }, capacity.totals)
  end

  should "count an unrecorded FTE as 1 and say so in the working" do
    choose(families: { @engineering_family.role_family_id => per_fte })
    dee = seat(capacity, @dee.id)

    assert_nil dee.places.first.unit_id
    assert_equal 1r, dee.places.first.figure.amount
    assert_equal "FTE not recorded, counted as 1", dee.places.first.figure.working.first.label
    assert_not dee.seat.fte_known
  end

  should "list each place no model covers as unclassified with why, and count it nowhere" do
    choose(families: { @engineering_family.role_family_id => { model: "per_fte" } })
    as_tenant { FrameworkState::Role.where(role_id: @manager.role_id).delete_all }
    report = capacity

    reasons = report.unclassified.map { |seat, place| [ seat.seat.id, place.reason ] }
    assert_equal [ [ @brook.id, "unknown_role" ], [ @brook.id, "unknown_role" ], [ @cy.id, "unmapped_title" ] ].sort, reasons.sort
    assert_equal({ "per_fte" => 2r }, report.totals)
    assert_nil report.units[@payments]
  end

  should "list each place that counts nowhere as needing attention, naming why, once the plan measures capacity" do
    attention = lambda do
      as_tenant { TeamPlanning::Attention.for(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id: @plan_id) }
        .select { it.facet.start_with?("#{TeamPlanning::Attention::CAPACITY}:") }
    end
    assert_empty attention.call

    choose(families: { @engineering_family.role_family_id => per_fte })
    items = attention.call

    assert_equal [ [ @cy.id, "capacity:#{@payments}", "Counts for no capacity: the person's title maps to no role" ] ],
                 items.map { [ it.subject_id, it.facet, it.reason ] }
  end

  should "say when a chosen model is no longer available" do
    model = Class.new(TeamPlanning::CapacityModel) do
      def self.model_name = "test_gone"
      def self.description = "Gone soon"
      def self.check(params) = params
    end
    TeamPlanning::CapacityModels.register(model)
    choose(families: { @engineering_family.role_family_id => { model: "test_gone" } })
    TeamPlanning::CapacityModels.unregister(model)

    place = seat(capacity, @ada.id).places.first
    assert_equal [ "test_gone", "unknown_model" ], [ place.model, place.reason ]
  ensure
    TeamPlanning::CapacityModels.unregister(model) if TeamPlanning::CapacityModels.registered?("test_gone")
  end

  should "read the family from this tenant's framework only" do
    design = SecureRandom.uuid_v7
    as_tenant(create(:tenant)) { create(:framework_role, role_id: @manager.role_id, code: "EM", role_family_id: design) }
    choose(families: { design => per_fte })

    assert_equal [ "no_model" ], seat(capacity, @brook.id).places.map(&:reason).uniq
  end

  should "price in units, charging a manager for their reports before splitting the seat, with a working that reaches each figure" do
    as_tenant { OrgGraph::CommandHandler.new(actor: SYSTEM).change_manager(@ada.id, @brook.id, **ESPALIA) }
    choose(families: { @engineering_family.role_family_id => { model: "units" } })
    report = capacity

    brook = seat(report, @brook.id)
    assert_equal [ Rational(1, 2), Rational(1, 2) ], brook.places.map { it.figure.amount }
    assert_equal [ [ "Report, direct, L5", @ada.id ] ], brook.places.first.figure.working.filter_map { [ it.label, it.subject_id ] if it.subject_id }
    assert_equal Rational("1.45"), seat(report, @ada.id).places.first.figure.amount
    assert_equal({ "units" => Rational("3.9") }, report.totals)
  end

  should "price a place in a position at the position's level, though the person's own level differs" do
    choose(families: { @engineering_family.role_family_id => { model: "units" } })
    e3 = as_tenant { create(:framework_level, role_id: @engineer.role_id, ordinal: 3, title: "SWE") }
    position_id = open_position(level: e3, fte: 1)
    place_in(@ada, [ { position_id:, allocation: 1 } ])

    place = seat(capacity, @ada.id).places.first
    assert_equal [ nil, Rational("1.0") ], [ place.reason, place.figure.amount ]
  end

  should "price a leaver as nothing, and charge their reports to the position backfilling them" do
    choose(families: { @engineering_family.role_family_id => { model: "units" } })
    as_tenant do
      people = OrgGraph::CommandHandler.new(actor: SYSTEM)
      people.change_manager(@dee.id, @ada.id, **ESPALIA)
      people.change_manager(@brook.id, @cy.id, **ESPALIA)
    end
    backfill = open_position(unit_id: @engineering)
    operation(Operations::TeamPlanning::SetDeparture, person_id: @ada.id, position_id: backfill)
    report = capacity

    assert_equal [ "leaving" ], seat(report, @ada.id).places.map(&:reason)
    working = seat(report, backfill).places.first.figure.working
    assert_equal [ @dee.id ], working.filter_map(&:subject_id)
    assert_equal "Fixed cost of managing at L5", working.second.label
  end

  should "refuse someone who isn't on the plan" do
    stranger = as_tenant { create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant)) }

    assert_raises(Pundit::NotAuthorizedError) { capacity(as: stranger) }
  end

  should "place a planned level, though the title's mapping fixes a level" do
    config = @tenant.hris_config
    config.role_mappings.first.level_ordinal = 4
    @tenant.update!(hris_config: config)
    as_tenant { handler.set_change(@plan_id, TeamPlanning::Events::LevelSet, scenario_id: @plan_id, subject_id: @ada.id, end_state: { level: "5" }) }

    ada = seat(capacity, @ada.id)
    place = ada.places.sole.place
    assert_equal [ @engineer.role_id, @e5.level_id, true ], [ place.role_id, place.level_id, ada.own_level ]
  end

  should "leave a planned level that names no ordinal unresolved, though the title's mapping fixes a level" do
    config = @tenant.hris_config
    config.role_mappings.first.level_ordinal = 5
    @tenant.update!(hris_config: config)
    as_tenant { handler.set_change(@plan_id, TeamPlanning::Events::LevelSet, scenario_id: @plan_id, subject_id: @ada.id, end_state: { level: "Senior" }) }

    ada = seat(capacity, @ada.id)
    place = ada.places.sole.place
    assert_equal [ @engineer.role_id, nil, false ], [ place.role_id, place.level_id, ada.own_level ]
  end

  should "keep a removed planned level unknown, though the title's mapping fixes a level" do
    config = @tenant.hris_config
    config.role_mappings.first.level_ordinal = 5
    @tenant.update!(hris_config: config)
    as_tenant { handler.set_change(@plan_id, TeamPlanning::Events::LevelSet, scenario_id: @plan_id, subject_id: @ada.id, end_state: { level: "6" }) }
    as_tenant { PlanKeyStore.new.destroy_person(@ada.id) }

    place = seat(capacity, @ada.id).places.sole.place
    assert_equal [ @engineer.role_id, nil ], [ place.role_id, place.level_id ]
  end
end
