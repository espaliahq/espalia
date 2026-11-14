# frozen_string_literal: true

require "test_helper"

class TeamPlanning::CapacityTest < ActiveSupport::TestCase
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

  def capacity(as: @planner)
    as_tenant { TeamPlanning::Capacity.new(context: context_for(as), plan: TeamPlanningPlan.find(@plan_id), scenario_id: @plan_id).call }
  end

  def seat(report, id) = report.seats.find { it.seat.id == id }

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

  should "refuse someone who isn't on the plan" do
    stranger = as_tenant { create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant)) }

    assert_raises(Pundit::NotAuthorizedError) { capacity(as: stranger) }
  end
end
