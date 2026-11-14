# frozen_string_literal: true

require "test_helper"

class TeamPlanning::BaselineTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  BASE_ON = Date.new(2026, 3, 2)

  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::CommandHandler.new(actor: SYSTEM)
    @structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    departments, squads = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    @engineering, @payments, @platform = Array.new(3) { SecureRandom.uuid_v7 }

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      @brook = create(:person, tenant: @tenant, name: "Brook Tamsin")
      @grace = create(:person, tenant: @tenant, name: "Grace Hollis")
      @structure.define_taxonomy([ { level_id: departments, name: "Department" }, { level_id: squads, name: "Squad" } ],
                                  effective_on: "2026-01-01")
      @structure.create_unit(@engineering, "Engineering", level_id: departments, effective_on: "2026-01-01")
      @structure.create_unit(@payments, "Payments", level_id: squads, parent_id: @engineering, effective_on: "2026-01-01")
      @structure.create_unit(@platform, "Platform", level_id: squads, parent_id: @engineering, effective_on: "2026-01-01")
      @handler.record_person(@ada.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed",
                             title: "Engineer", manager_id: @grace.id, fte: 1.0)
      [ @brook, @grace ].each { @handler.record_person(it.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed") }
      @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0, role: "Lead")
      @handler.set_membership(@brook.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 0.5)
      @handler.set_membership(@brook.id, @platform, **ESPALIA, effective_on: "2026-02-01", allocation: 0.5, role: "Tech lead")
      @structure.add_unit_owner(@payments, @ada.id, effective_on: "2026-02-01")

      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      TeamPlanning::CommandHandler.new(actor: context_for(@planner)).create_plan(@plan_id, name: "Next year", base_on: BASE_ON)
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def context_for(tenant_user) = AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)

  def baseline(as: @planner, names: true)
    as_tenant do
      reader = TeamPlanning::Baseline.new(context: context_for(as), plan: TeamPlanningPlan.find(@plan_id))
      names ? reader.call : reader.structure
    end
  end

  def person(map, person) = map.people.find { it.id == person.id }

  should "show the organisation on the base date, as known the day before, by id" do
    map = baseline

    assert_equal [ BASE_ON, BASE_ON - 1 ], [ map.base_on, map.known_on ]
    payments = map.units.find { it.id == @payments }
    assert_equal [ "Payments", @engineering, [ @ada.id ] ], [ payments.name, payments.parent_id, payments.owner_ids ]
    assert_equal %w[Engineering Payments Platform], map.units.map(&:name)

    ada = person(map, @ada)
    assert_equal [ "Engineer", @grace.id, 1.0 ], [ ada.title, ada.manager_id, ada.fte ]
    assert_equal [ TeamPlanning::Baseline::Membership.new(unit_id: @payments, allocation: 1.0, role: "Lead") ], ada.memberships
    assert_equal [ [ @payments, 0.5, nil ], [ @platform, 0.5, "Tech lead" ] ].sort_by(&:first),
                 person(map, @brook).memberships.map { [ it.unit_id, it.allocation, it.role ] }.sort_by(&:first)
  end

  should "put the people in no unit in the Unassigned bucket" do
    assert_equal [ @grace.id ], baseline.unassigned_ids
  end

  should "name nobody in the structure, and join names only at the end" do
    assert_empty baseline(names: false).names

    map = baseline
    assert_equal [ "Ada Quill", "Grace Hollis" ], [ map.name_of(@ada.id), map.name_of(person(map, @ada).manager_id) ]
  end

  should "leave out an edit the Org Graph learned on the base date, which arrives as drift" do
    travel_to Time.utc(2026, 3, 2, 10)
    as_tenant do
      @handler.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: BASE_ON)
      @handler.set_membership(@grace.id, @platform, **ESPALIA, effective_on: BASE_ON)
    end

    map = baseline
    assert_equal "Engineer", person(map, @ada).title
    assert_equal [ @grace.id ], map.unassigned_ids
  end

  should "show the later of two changes to one fact taking effect on the base date, both known before it" do
    travel_to Time.utc(2026, 2, 10, 9)
    as_tenant { @handler.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: BASE_ON) }
    travel_to Time.utc(2026, 2, 11, 9)
    as_tenant { @handler.change_title(@ada.id, "Staff Engineer", **ESPALIA, effective_on: BASE_ON) }

    assert_equal "Staff Engineer", person(baseline, @ada).title
  end

  should "leave out someone who left before the base date, with their places" do
    as_tenant { @handler.leave(@brook.id, **ESPALIA, effective_on: "2026-02-20") }

    map = baseline
    assert_nil person(map, @brook)
    assert_equal [ @grace.id ], map.unassigned_ids
  end

  should "show a forgotten person as a former member" do
    as_tenant { @ada.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current) }

    map = baseline
    assert_equal Person::FORMER_MEMBER, map.name_of(@ada.id)
    assert_equal Person::FORMER_MEMBER, map.name_of(SecureRandom.uuid_v7), "anyone the map can't name"
  end

  should "show nothing from another tenant" do
    other = create(:tenant)
    ActsAsTenant.with_tenant(other) do
      stranger = create(:person, tenant: other)
      @handler.record_person(stranger.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed")
    end

    assert_equal [ @ada.id, @brook.id, @grace.id ].sort, baseline.people.map(&:id).sort
  end

  should "refuse anyone but the plan's creator, a tenant admin included" do
    other_admin = as_tenant { create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant)) }

    assert_raises(Pundit::NotAuthorizedError) { baseline(as: other_admin) }
  end
end
