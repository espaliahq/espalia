# frozen_string_literal: true

require "test_helper"

class TeamPlanning::DriftTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  BASE_ON = Date.new(2026, 3, 2)

  # Test-only kinds standing in for those 3.3 to 3.7 add: one fact, and the
  # placement list, which every membership change moves as a whole.
  class TitleSet < TeamPlanning::Events::Change
    def self.facet = "title"
    def self.apply_to(map, _data) = map
    def self.subject_moved_by(change) = (change.person_id if change.kind == :fact_changed && change.fact == "title")
  end

  class PlacementsSet < TeamPlanning::Events::Change
    PLACEMENT_KINDS = %i[membership_started membership_ended membership_changed moved].freeze

    def self.facet = "placements"
    def self.apply_to(map, _data) = map
    def self.subject_moved_by(change) = (change.person_id if PLACEMENT_KINDS.include?(change.kind))
  end

  setup do
    @tenant = create(:tenant)
    @org = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    @squads = squads = SecureRandom.uuid_v7
    @payments, @platform = Array.new(2) { SecureRandom.uuid_v7 }

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      @brook = create(:person, tenant: @tenant, name: "Brook Tamsin")
      structure.define_taxonomy([ { level_id: squads, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: squads, effective_on: "2026-01-01")
      structure.create_unit(@platform, "Platform", level_id: squads, effective_on: "2026-01-01")
      [ @ada, @brook ].each do
        @org.record_person(it.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", title: "Engineer")
        @org.set_membership(it.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
      end

      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: BASE_ON)
      @q1 = SecureRandom.uuid_v7.tap { handler.fork_scenario(@plan_id, it, parent_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30") }
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def context_for(tenant_user) = AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)

  def handler(as = @planner) = TeamPlanning::CommandHandler.new(actor: context_for(as))

  def plan(kind, subject, scenario_id = @q1, **end_state)
    as_tenant { handler.set_change(@plan_id, kind, scenario_id:, subject_id: subject.id, end_state:) }
  end

  def on(time, &) = travel_to(time) { as_tenant(&) }

  def drift(as: @planner, today: Date.new(2026, 4, 1))
    as_tenant { TeamPlanning::Drift.new(context: context_for(as), plan: TeamPlanningPlan.find(@plan_id), today:).call }
  end

  def kinds(report) = report.changes.map { [ it.change.kind, it.change.person_id ] }

  should "read what the Org Graph learned from the base date on, and leave out what the baseline already held" do
    on(Time.utc(2026, 3, 1, 12)) { @org.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-01") }
    on(Time.utc(2026, 3, 2, 8)) { @org.change_title(@brook.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-02") }

    report = drift
    assert_equal [ Date.new(2026, 3, 1), Date.new(2026, 4, 1) ], [ report.from, report.to ]
    assert_equal [ [ :fact_changed, @brook.id ] ], kinds(report)
  end

  should "show a backdated correction learned since the base, with the day it took effect" do
    on(Time.utc(2026, 3, 10, 9)) { @org.change_title(@ada.id, "Staff Engineer", **ESPALIA, effective_on: "2026-02-15") }

    change = drift.changes.sole
    assert_equal [ Date.new(2026, 2, 15), { "title" => "Engineer" }, [] ], [ change.change.effective_on, change.change.before, change.outside ]
  end

  should "say which of the plan's changes a drift meets, in every scenario that holds one" do
    plan(TitleSet, @ada, @plan_id, title: "Lead Engineer")
    plan(TitleSet, @ada, title: "Senior Engineer")
    plan(TitleSet, @ada, title: "Staff Engineer")
    plan(TitleSet, @brook, title: "Senior Engineer")
    on(Time.utc(2026, 3, 10, 9)) { @org.change_title(@ada.id, "Principal Engineer", **ESPALIA, effective_on: "2026-03-10") }

    meets = drift.changes.sole.meets
    assert_equal [ [ @plan_id, "title", @ada.id ], [ @q1, "title", @ada.id ] ], meets.map { [ it.scenario_id, it.facet, it.subject_id ] }
    staff = as_tenant { TeamPlanning::Repository.new.load_plan(@plan_id).changes_in(@q1).select { it.data[:subject_id] == @ada.id }.last }
    assert_equal staff.event_id, meets.last.change_id, "the scenario's latest change for the facet"
  end

  should "meet no planned change in a facet the drift doesn't move" do
    plan(TitleSet, @ada, title: "Senior Engineer")
    on(Time.utc(2026, 3, 10, 9)) { @org.set_membership(@ada.id, @platform, **ESPALIA, effective_on: "2026-03-10", allocation: 0.5) }

    assert_empty drift.changes.sole.meets
  end

  should "meet a planned placement list as a whole when one placement moves" do
    plan(PlacementsSet, @ada, placements: [ { unit_id: @payments, allocation: 0.5 }, { unit_id: @platform, allocation: 0.5 } ])
    on(Time.utc(2026, 3, 10, 9)) { @org.move_membership(@brook.id, @payments, @platform, effective_on: "2026-03-10") }
    on(Time.utc(2026, 3, 11, 9)) { @org.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-11", allocation: 0.8) }

    report = drift
    assert_equal [ [ :moved, @brook.id ], [ :membership_changed, @ada.id ] ], kinds(report)
    assert_equal [ [], [ "placements" ] ], report.changes.map { it.meets.map(&:facet) }
  end

  should "meet a planned retirement when the Org Graph retires the unit, and no planned succession" do
    as_tenant do
      handler.set_change(@plan_id, TeamPlanning::Events::UnitRetired, scenario_id: @q1, subject_id: @platform,
                                                                       end_state: { name: "Platform", parent_id: nil, level_id: @squads })
      handler.set_change(@plan_id, TeamPlanning::Events::UnitSuccessionSet, scenario_id: @q1, subject_id: SecureRandom.uuid_v7,
                                                                            end_state: { predecessor_ids: [ @platform ], successor_ids: [ @payments ] })
    end
    on(Time.utc(2026, 3, 10, 9)) do
      OrgGraph::StructureCommandHandler.new(actor: SYSTEM).record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @platform ], successor_ids: [ @payments ],
                                                                                                 effective_on: "2026-03-10", retire_predecessors: true)
    end

    met = drift.changes.flat_map(&:meets)
    assert_equal [ [ @platform, "unit" ] ], met.map { [ it.subject_id, it.facet ] }
  end

  should "show a change the Org Graph learned before the base and no longer believes as withdrawn" do
    plan(PlacementsSet, @ada, placements: [ { unit_id: @platform, allocation: 1.0 } ])
    on(Time.utc(2026, 2, 20, 9)) { @org.move_membership(@ada.id, @payments, @platform, effective_on: "2026-03-15") }
    on(Time.utc(2026, 3, 10, 9)) do
      OrgGraph::ChangeBackHandler.new(actor: SYSTEM).change_back(OrgUnitActivity.for_unit(@platform).first)
    end

    withdrawn = drift.changes.sole
    assert_equal [ :moved, Date.new(2026, 3, 15), true ], withdrawn.change.to_h.values_at(:kind, :effective_on, :withdrawn)
    assert_equal [ "placements" ], withdrawn.meets.map(&:facet), "it still says which planned change it meets"
  end

  should "mark a change applied from this plan, and not one from another plan or a direct edit" do
    other_plan = SecureRandom.uuid_v7
    on(Time.utc(2026, 3, 10, 9)) do
      @org.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-10", plan_id: @plan_id, plan_change_id: SecureRandom.uuid_v7)
      @org.change_title(@brook.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-10", plan_id: other_plan, plan_change_id: SecureRandom.uuid_v7)
    end
    on(Time.utc(2026, 3, 11, 9)) { @org.change_title(@brook.id, "Staff Engineer", **ESPALIA, effective_on: "2026-03-11") }

    assert_equal [ true, false, false ], drift.changes.map(&:from_plan)
  end

  context "a structure declared and withdrawn since the base" do
    setup do
      @cards, @wallet = Array.new(2) { SecureRandom.uuid_v7 }
      @pod = SecureRandom.uuid_v7
      structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
      as_tenant do
        structure.set_kind_parents(@squads, parent_ids: [ @squads ], top: true, effective_on: "2026-01-01")
        structure.create_unit(@cards, "Cards", level_id: @squads, parent_id: @payments, effective_on: "2026-01-01")
        structure.create_unit(@wallet, "Wallet", level_id: @squads, parent_id: @payments, effective_on: "2026-01-01")
      end
      admin = OrgGraph::StructureCommandHandler.new(actor: context_for(@planner))
      on(Time.utc(2026, 3, 5, 9)) do
        admin.declare_structure(@payments, levels: [ { level_id: @pod, name: "Pod" } ], conversion: { @squads => @pod }, effective_on: "2026-03-05")
      end
      on(Time.utc(2026, 3, 9, 9)) { admin.withdraw_structure(@payments, conversion: { @pod => @squads }, effective_on: "2026-03-09") }
    end

    should "read each as one change naming the declaring unit and every unit it retyped, keyed by its cause" do
      report = drift
      items = report.changes.map { [ it.change.kind, it.change.unit_id, it.group&.unit_ids&.sort ] }

      assert_equal [ [ :structure_declared, @payments, [ @cards, @wallet ].sort ], [ :structure_withdrawn, @payments, [ @cards, @wallet ].sort ] ], items
      assert_equal report.changes.map { it.change.event_id }, drift.changes.map { it.change.event_id }
      assert_equal report.changes.map { it.group.cause_id }, report.changes.map { it.change.event_id }
      assert_equal "Payments", report.names[@payments]
    end
  end

  should "have no drift while the base is still to come" do
    on(Time.utc(2026, 2, 20, 9)) { @org.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-02-20") }

    assert_empty drift(today: Date.new(2026, 2, 20)).changes
    assert_empty drift(today: Date.new(2026, 3, 1)).changes
  end

  should "name the people a change names, and a forgotten person a former member" do
    on(Time.utc(2026, 3, 10, 9)) { @org.change_manager(@ada.id, @brook.id, **ESPALIA, effective_on: "2026-03-10") }

    report = drift
    assert_equal [ "Ada Quill", "Brook Tamsin" ], [ report.name_of(@ada.id), report.name_of(@brook.id) ]

    as_tenant { @brook.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current) }
    assert_equal Person::FORMER_MEMBER, drift.name_of(@brook.id)
  end

  should "let a viewer read the drift, and refuse anyone outside the plan, a tenant admin included" do
    viewer, outsider = as_tenant do
      Array.new(2) { create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant)) }
    end
    as_tenant { handler.add_member(@plan_id, viewer.person.id, role: "viewer") }

    assert_empty drift(as: viewer).changes
    assert_raises(Pundit::NotAuthorizedError) { drift(as: outsider) }
  end

  should "refuse another tenant's admin" do
    other = create(:tenant)
    stranger = ActsAsTenant.with_tenant(other) { create(:tenant_user, tenant: other, role: :admin, person: create(:person, tenant: other)) }

    assert_raises(Pundit::NotAuthorizedError) { drift(as: stranger) }
  end
end
