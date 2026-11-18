# frozen_string_literal: true

require "test_helper"

class TeamPlanning::StatusTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  BASE_ON = Date.new(2026, 3, 2)
  TODAY = Date.new(2026, 4, 1)

  # Test-only kinds: one fact the Org Graph holds, and a kind only the plan holds.
  class TitleSet < TeamPlanning::Events::Change
    def self.facet = "title"
    def self.apply_to(map, data) = map.with(people: map.people.map { it.id == data[:subject_id] ? it.with(title: data[:title]) : it })
    def self.subject_moved_by(change) = (change.person_id if change.kind == :fact_changed && change.fact == "title")

    def self.read_from(map, subject_id:, facet: self.facet)
      person = map.people.find { it.id == subject_id }
      { title: person.title } if person
    end
  end

  class NoteSet < TeamPlanning::Events::Change
    def self.facet = "note"
    def self.apply_to(map, _data) = map
    def self.read_from(_map, subject_id:, facet: self.facet) = { text: nil }
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
      @q1 = fork("Q1", parent_id: @plan_id, relation: "then", ends_on: "2026-06-30")
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def context_for(tenant_user) = AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)

  def handler(as = @planner) = TeamPlanning::CommandHandler.new(actor: context_for(as))

  def fork(name, parent_id:, relation:, **period)
    SecureRandom.uuid_v7.tap { handler.fork_scenario(@plan_id, it, parent_id:, relation:, name:, **period) }
  end

  def plan(kind, subject_id, scenario_id = @q1, **end_state)
    as_tenant { handler.set_change(@plan_id, kind, scenario_id:, subject_id:, end_state:) }
  end

  def on(time, &) = travel_to(time) { as_tenant(&) }

  def status(scenario_id = @q1, as: @planner)
    as_tenant { TeamPlanning::Status.new(context: context_for(as), plan: TeamPlanningPlan.find(@plan_id), scenario_id:, today: TODAY).call }
  end

  def statuses(report) = report.statuses.to_h { [ [ it.subject_id, it.facet ], it.status ] }

  def placements(*places) = places.map { |unit_id, allocation| { unit_id:, allocation: } }

  should "read done when today matches the end state, pending when it still matches the base, and conflicting otherwise" do
    plan(TitleSet, @ada.id, title: "Senior Engineer")
    plan(TitleSet, @brook.id, title: "Lead Engineer")
    on(Time.utc(2026, 3, 10, 9)) { @org.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-10") }

    assert_equal({ [ @ada.id, "title" ] => :done, [ @brook.id, "title" ] => :pending }, statuses(status))

    on(Time.utc(2026, 3, 20, 9)) { @org.change_title(@brook.id, "Staff Engineer", **ESPALIA, effective_on: "2026-03-20") }
    assert_equal :conflicting, statuses(status)[[ @brook.id, "title" ]]
  end

  should "keep a conflict an update carried forward in view, and drop it once the change is done or set again" do
    plan(TitleSet, @ada.id, title: "Senior Engineer")
    plan(TitleSet, @brook.id, title: "Lead Engineer")
    lean = as_tenant { fork("Lean Q1", parent_id: @q1, relation: "instead") }
    on(Time.utc(2026, 3, 20, 9)) { @org.change_title(@brook.id, "Staff Engineer", **ESPALIA, effective_on: "2026-03-20") }
    change_id = status.statuses.find { it.subject_id == @brook.id }.change_id
    on(Time.utc(2026, 3, 25, 9)) do
      conflicts = [ @q1, lean ].map { { scenario_id: it, subject_id: @brook.id, facet: "title", change_id: } }
      handler.rebase_plan(@plan_id, base_on: "2026-03-25", expected_base_on: BASE_ON, conflicts:)
    end

    [ @q1, lean ].each do |scenario_id|
      entries = status(scenario_id).statuses.index_by(&:subject_id)
      assert_equal [ :conflicting, Date.new(2026, 3, 25) ], entries[@brook.id].then { [ it.status, it.since ] }
      assert_equal [ :pending, nil ], entries[@ada.id].then { [ it.status, it.since ] }
    end

    on(Time.utc(2026, 3, 26, 9)) { @org.change_title(@brook.id, "Lead Engineer", **ESPALIA, effective_on: "2026-03-26") }
    assert_equal :done, statuses(status)[[ @brook.id, "title" ]]
    plan(TitleSet, @brook.id, title: "Principal Engineer")
    assert_equal [ :conflicting, nil ], status.statuses.find { it.subject_id == @brook.id }.then { [ it.status, it.since ] }
  end

  should "read against the updated base when a reader is used again after an update to today" do
    plan(TitleSet, @brook.id, title: "Lead Engineer")
    reader = as_tenant { TeamPlanning::Status.new(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id: @q1, today: TODAY) }
    on(Time.utc(2026, 3, 20, 9)) { @org.change_title(@brook.id, "Staff Engineer", **ESPALIA, effective_on: "2026-03-20") }
    on(Time.utc(2026, 3, 25, 9)) { handler.rebase_plan(@plan_id, base_on: "2026-03-25", expected_base_on: BASE_ON) }
    plan(TitleSet, @brook.id, title: "Principal Engineer")

    assert_equal :pending, statuses(as_tenant { reader.call })[[ @brook.id, "title" ]]
  end

  should "carry each change's own scenario and event, and read the latest change to a facet" do
    plan(TitleSet, @ada.id, title: "Lead Engineer")
    latest = plan(TitleSet, @ada.id, title: "Senior Engineer").changes_in(@q1).last

    entry = status.statuses.sole
    assert_equal [ @q1, latest.event_id, @ada.id, "title", :pending ],
                 [ entry.scenario_id, entry.change_id, entry.subject_id, entry.facet, entry.status ]
    assert_equal TODAY, status.on
  end

  should "read an alternative's own change over its parent's, and inherit the rest" do
    alternative = as_tenant { fork("Lean Q1", parent_id: @q1, relation: "instead") }
    plan(TitleSet, @ada.id, title: "Senior Engineer")
    plan(TitleSet, @brook.id, title: "Lead Engineer")
    plan(TitleSet, @ada.id, alternative, title: "Staff Engineer")
    on(Time.utc(2026, 3, 10, 9)) { @org.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-10") }

    assert_equal :done, statuses(status)[[ @ada.id, "title" ]]
    report = status(alternative)
    assert_equal({ [ @ada.id, "title" ] => :conflicting, [ @brook.id, "title" ] => :pending }, statuses(report))
    assert_equal({ @ada.id => alternative, @brook.id => @q1 }, report.statuses.to_h { [ it.subject_id, it.scenario_id ] })
  end

  should "read a placement list done only when the whole list matches" do
    plan(TeamPlanning::Events::AssignmentSet, @brook.id, placements: placements([ @platform, 0.5 ], [ @payments, 0.5 ]))
    assert_equal :pending, statuses(status)[[ @brook.id, "assignment" ]]

    on(Time.utc(2026, 3, 10, 9)) { @org.set_membership(@brook.id, @platform, **ESPALIA, effective_on: "2026-03-10", allocation: 0.5) }

    assert_equal :conflicting, statuses(status)[[ @brook.id, "assignment" ]]

    on(Time.utc(2026, 3, 11, 9)) { @org.set_membership(@brook.id, @payments, **ESPALIA, effective_on: "2026-03-11", allocation: 0.5) }
    assert_equal :done, statuses(status)[[ @brook.id, "assignment" ]]
  end

  should "read a position placement pending until the person is in the position's unit at its allocation, then done" do
    position = SecureRandom.uuid_v7
    plan(TeamPlanning::Events::PositionSet, position, role_id: SecureRandom.uuid_v7, level_id: SecureRandom.uuid_v7,
                                                      unit_id: @platform, fte: 1.0, basis: "backfill")
    plan(TeamPlanning::Events::AssignmentSet, @brook.id, placements: [ { position_id: position, allocation: 1.0 } ])
    assert_equal :pending, statuses(status)[[ @brook.id, "assignment" ]]

    on(Time.utc(2026, 3, 10, 9)) do
      @org.end_membership(@brook.id, @payments, **ESPALIA, effective_on: "2026-03-10")
      @org.set_membership(@brook.id, @platform, **ESPALIA, effective_on: "2026-03-10", allocation: 1.0)
    end
    assert_equal :done, statuses(status)[[ @brook.id, "assignment" ]]
  end

  should "settle positions afresh on each read, so a reader used again sees a position the plan has moved" do
    position = SecureRandom.uuid_v7
    move = ->(unit_id) do
      plan(TeamPlanning::Events::PositionSet, position, role_id: @squads, level_id: @squads, unit_id:, fte: 1.0, basis: "new")
    end
    move.(@platform)
    plan(TeamPlanning::Events::AssignmentSet, @brook.id, placements: [ { position_id: position, allocation: 1.0 } ])
    reader = as_tenant { TeamPlanning::Status.new(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id: @q1, today: TODAY) }
    assert_not_equal :done, statuses(as_tenant { reader.call })[[ @brook.id, "assignment" ]]

    move.(@payments)
    assert_equal :done, statuses(as_tenant { reader.call })[[ @brook.id, "assignment" ]]
  end

  should "read pending while today matches the step before, and conflicting once it leaves both" do
    plan(TitleSet, @ada.id, title: "Senior Engineer")
    q2 = as_tenant { fork("Q2", parent_id: @q1, relation: "then", ends_on: "2026-09-30") }
    plan(TitleSet, @ada.id, q2, title: "Lead Engineer")
    on(Time.utc(2026, 3, 10, 9)) { @org.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-10") }

    assert_equal :pending, statuses(status(q2))[[ @ada.id, "title" ]]

    on(Time.utc(2026, 3, 20, 9)) { @org.change_title(@ada.id, "Staff Engineer", **ESPALIA, effective_on: "2026-03-20") }
    assert_equal :conflicting, statuses(status(q2))[[ @ada.id, "title" ]]
  end

  should "read pending while someone who joined after the base holds the place the step before plans" do
    hire = as_tenant { create(:person, tenant: @tenant, name: "Cass Rowe") }
    on(Time.utc(2026, 3, 10, 9)) do
      @org.record_person(hire.id, **ESPALIA, effective_on: "2026-03-10", employment_status: "employed", title: "Engineer")
      @org.set_membership(hire.id, @payments, **ESPALIA, effective_on: "2026-03-10", allocation: 1.0)
    end
    plan(TeamPlanning::Events::AssignmentSet, hire.id, placements: placements([ @payments, 1.0 ]))
    q2 = as_tenant { fork("Q2", parent_id: @q1, relation: "then", ends_on: "2026-09-30") }
    plan(TeamPlanning::Events::AssignmentSet, hire.id, q2, placements: placements([ @platform, 1.0 ]))

    assert_equal :pending, statuses(status(q2))[[ hire.id, "assignment" ]]
  end

  should "hold a plan whose base is still to come against today, so nothing reads conflicting" do
    on(Time.utc(2026, 3, 1, 9)) { @org.change_title(@brook.id, "Staff Engineer", **ESPALIA, effective_on: "2026-05-01") }
    later = SecureRandom.uuid_v7
    as_tenant { handler.create_plan(later, name: "Later", base_on: Date.new(2026, 6, 1)) }
    as_tenant { handler.set_change(later, TitleSet, scenario_id: later, subject_id: @brook.id, end_state: { title: "Lead Engineer" }) }

    report = as_tenant { TeamPlanning::Status.new(context: context_for(@planner), plan: TeamPlanningPlan.find(later), scenario_id: later, today: TODAY).call }
    assert_equal [ :pending ], report.statuses.map(&:status)
  end

  should "read pending for a subject only the plan holds, and conflicting for one who has since left" do
    plan(TitleSet, SecureRandom.uuid_v7, title: "Engineer")
    plan(TitleSet, @brook.id, title: "Lead Engineer")
    on(Time.utc(2026, 3, 10, 9)) { @org.leave(@brook.id, **ESPALIA, effective_on: "2026-03-10") }

    assert_equal %i[pending conflicting], status.statuses.map(&:status)
  end

  should "read a unit the plan renames done once the Org Graph renames it, and conflicting once it retires it" do
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    plan(TeamPlanning::Events::UnitSet, @payments, name: "Payments Core", parent_id: nil, level_id: @squads)
    assert_equal :pending, statuses(status)[[ @payments, "unit" ]]

    on(Time.utc(2026, 3, 10, 9)) { structure.rename_unit(@payments, "Payments Core", effective_on: "2026-03-10") }
    assert_equal :done, statuses(status)[[ @payments, "unit" ]]

    on(Time.utc(2026, 3, 20, 9)) { structure.retire_unit(@payments, effective_on: "2026-03-20") }
    assert_equal :conflicting, statuses(status)[[ @payments, "unit" ]]
  end

  should "read a unit the plan renames done once the Org Graph renames it, whatever type the Org Graph has given it since" do
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    tribe = SecureRandom.uuid_v7
    on(Time.utc(2026, 2, 1, 9)) { structure.add_level(tribe, "Tribe", parent_ids: [], top: true, effective_on: "2026-01-01") }
    plan(TeamPlanning::Events::UnitSet, @payments, name: "Payments Core", parent_id: nil, level_id: @squads)

    on(Time.utc(2026, 3, 10, 9)) { structure.change_unit_kind(@payments, tribe, effective_on: "2026-03-10") }
    assert_equal :pending, statuses(status)[[ @payments, "unit" ]], "a type the plan never set is no conflict"

    on(Time.utc(2026, 3, 12, 9)) { structure.rename_unit(@payments, "Payments Core", effective_on: "2026-03-12") }
    assert_equal :done, statuses(status)[[ @payments, "unit" ]]
  end

  should "resolve a unit the Org Graph holds to its type at the base, even a retired one the plan restores, and keep a plan's own unit's type" do
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    tribe, risk = Array.new(2) { SecureRandom.uuid_v7 }
    on(Time.utc(2026, 2, 10, 9)) do
      structure.add_level(tribe, "Tribe", parent_ids: [], top: true, effective_on: "2026-01-01")
      structure.change_unit_kind(@platform, tribe, effective_on: "2026-02-10")
      structure.change_unit_kind(@payments, tribe, effective_on: "2026-02-10")
      structure.retire_unit(@platform, effective_on: "2026-02-10")
    end
    plan(TeamPlanning::Events::UnitSet, @platform, name: "Platform", parent_id: nil, level_id: @squads)
    plan(TeamPlanning::Events::UnitSet, @payments, name: "Payments Core", parent_id: nil, level_id: @squads)
    plan(TeamPlanning::Events::UnitSet, risk, name: "Risk", parent_id: nil, level_id: @squads)

    resolved = as_tenant do
      TeamPlanning::Resolution.new(context: context_for(@planner), plan: TeamPlanningPlan.find(@plan_id), scenario_id: @q1).structure
    end
    assert_equal({ @platform => tribe, @payments => tribe, risk => @squads }, resolved.units.to_h { [ it.id, it.level_id ] })
  end

  should "read a unit the plan restores pending while the Org Graph has retired it, as the step before plans" do
    plan(TeamPlanning::Events::UnitRetired, @payments, name: "Payments", parent_id: nil, level_id: @squads)
    q2 = as_tenant { fork("Q2", parent_id: @q1, relation: "then", ends_on: "2026-09-30") }
    plan(TeamPlanning::Events::UnitSet, @payments, q2, name: "Payments", parent_id: nil, level_id: @squads)
    on(Time.utc(2026, 3, 10, 9)) { OrgGraph::StructureCommandHandler.new(actor: SYSTEM).retire_unit(@payments, effective_on: "2026-03-10") }

    assert_equal :pending, statuses(status(q2))[[ @payments, "unit" ]]
  end

  should "read a planned retirement pending while the unit is live, and done once the Org Graph retires it" do
    plan(TeamPlanning::Events::UnitRetired, @platform, name: "Platform", parent_id: nil, level_id: @squads)
    assert_equal :pending, statuses(status)[[ @platform, "unit" ]]

    on(Time.utc(2026, 3, 10, 9)) do
      structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
      structure.rename_unit(@platform, "Platform Old", effective_on: "2026-03-10")
      structure.retire_unit(@platform, effective_on: "2026-03-10")
    end
    assert_equal :done, statuses(status)[[ @platform, "unit" ]]
    assert_equal "Platform Old", status.name_of(@platform)
  end

  should "find a planned succession by its predecessors: pending until recorded, conflicting when it names other successors" do
    merged, elsewhere = Array.new(2) { SecureRandom.uuid_v7 }
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    on(Time.utc(2026, 2, 1, 9)) do
      structure.create_unit(merged, "Money", level_id: @squads, effective_on: "2026-01-01")
      structure.create_unit(elsewhere, "Core", level_id: @squads, effective_on: "2026-01-01")
    end
    planned = SecureRandom.uuid_v7
    plan(TeamPlanning::Events::UnitSuccessionSet, planned, predecessor_ids: [ @payments, @platform ], successor_ids: [ merged ])
    assert_equal :pending, statuses(status)[[ planned, "succession" ]]

    on(Time.utc(2026, 3, 10, 9)) do
      structure.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @payments ], successor_ids: [ elsewhere ], effective_on: "2026-03-10")
    end
    assert_equal :conflicting, statuses(status)[[ planned, "succession" ]]
  end

  should "read a merge done when the Org Graph records it in parts, and leave out a succession it held before the base" do
    merged, earlier = Array.new(2) { SecureRandom.uuid_v7 }
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    on(Time.utc(2026, 2, 1, 9)) do
      structure.create_unit(merged, "Money", level_id: @squads, effective_on: "2026-01-01")
      structure.create_unit(earlier, "Billing", level_id: @squads, effective_on: "2026-01-01")
      structure.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @payments ], successor_ids: [ earlier ], effective_on: "2026-02-01")
    end
    planned = SecureRandom.uuid_v7
    plan(TeamPlanning::Events::UnitSuccessionSet, planned, predecessor_ids: [ @payments, @platform ], successor_ids: [ merged ])
    assert_equal :pending, statuses(status)[[ planned, "succession" ]]

    on(Time.utc(2026, 3, 10, 9)) do
      [ @payments, @platform ].each do
        structure.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ it ], successor_ids: [ merged ], effective_on: "2026-03-10")
      end
    end
    assert_equal :done, statuses(status)[[ planned, "succession" ]]
  end

  should "read a line to a person done once the Org Graph names that manager" do
    plan(TeamPlanning::Events::ReportingLineSet, @brook.id, manager_id: @ada.id)
    assert_equal :pending, statuses(status)[[ @brook.id, "reporting_line" ]]

    on(Time.utc(2026, 3, 10, 9)) { @org.change_manager(@brook.id, @ada.id, **ESPALIA, effective_on: "2026-03-10") }
    assert_equal :done, statuses(status)[[ @brook.id, "reporting_line" ]]
  end

  should "read a line to a seat done once the Org Graph names someone the plan seats there, and conflicting for anyone else" do
    seat = SecureRandom.uuid_v7
    plan(TeamPlanning::Events::PositionSet, seat, role_id: SecureRandom.uuid_v7, level_id: SecureRandom.uuid_v7,
                                                  unit_id: @payments, fte: 1.0, basis: "new")
    plan(TeamPlanning::Events::AssignmentSet, @ada.id, placements: [ { position_id: seat, allocation: 1.0 } ])
    plan(TeamPlanning::Events::ReportingLineSet, @brook.id, manager_position_id: seat)
    assert_equal :pending, statuses(status)[[ @brook.id, "reporting_line" ]]

    on(Time.utc(2026, 3, 10, 9)) { @org.change_manager(@brook.id, @ada.id, **ESPALIA, effective_on: "2026-03-10") }
    assert_equal :done, statuses(status)[[ @brook.id, "reporting_line" ]]

    stranger = as_tenant { create(:person, tenant: @tenant, name: "Cleo Vance") }
    on(Time.utc(2026, 3, 20, 9)) do
      @org.record_person(stranger.id, **ESPALIA, effective_on: "2026-03-20", employment_status: "employed", title: "Engineer")
      @org.change_manager(@brook.id, stranger.id, **ESPALIA, effective_on: "2026-03-20")
    end
    assert_equal :conflicting, statuses(status)[[ @brook.id, "reporting_line" ]]
  end

  should "read a planned departure pending while the person stays, and done once the Org Graph has them leave" do
    plan(TeamPlanning::Events::DepartureSet, @brook.id, leaves_in_id: @q1)
    assert_equal :pending, statuses(status)[[ @brook.id, "departure" ]]

    on(Time.utc(2026, 3, 10, 9)) { @org.leave(@brook.id, **ESPALIA, effective_on: "2026-03-10") }
    assert_equal :done, statuses(status)[[ @brook.id, "departure" ]]
  end

  should "read a planned departure pending again once the Org Graph has the leaver back" do
    plan(TeamPlanning::Events::DepartureSet, @brook.id, leaves_in_id: @q1)
    on(Time.utc(2026, 3, 10, 9)) { @org.leave(@brook.id, **ESPALIA, effective_on: "2026-03-10") }
    on(Time.utc(2026, 3, 20, 9)) { @org.return_to_work(@brook.id, **ESPALIA, effective_on: "2026-03-20") }

    assert_equal :pending, statuses(status)[[ @brook.id, "departure" ]]
  end

  should "read a withdrawn departure done while the person stays, and conflicting once the Org Graph has them leave" do
    plan(TeamPlanning::Events::DepartureWithdrawn, @brook.id)
    assert_equal :done, statuses(status)[[ @brook.id, "departure" ]]

    on(Time.utc(2026, 3, 10, 9)) { @org.leave(@brook.id, **ESPALIA, effective_on: "2026-03-10") }
    withdrawn = status.statuses.find { it.subject_id == @brook.id }
    assert_equal :conflicting, withdrawn.status
    assert_equal "Brook Tamsin", status.name_of(@brook.id)
  end

  should "read a withdrawal of a departure the step before plans conflicting once the person has left" do
    plan(TeamPlanning::Events::DepartureSet, @brook.id, leaves_in_id: @q1)
    q2 = as_tenant { fork("Q2", parent_id: @q1, relation: "then", ends_on: "2026-09-30") }
    plan(TeamPlanning::Events::DepartureWithdrawn, @brook.id, q2)
    assert_equal :done, statuses(status(q2))[[ @brook.id, "departure" ]]

    on(Time.utc(2026, 3, 10, 9)) { @org.leave(@brook.id, **ESPALIA, effective_on: "2026-03-10") }
    assert_equal :conflicting, statuses(status(q2))[[ @brook.id, "departure" ]]
  end

  should "read a withdrawn departure for a hire the plan adds as staying" do
    plan(TeamPlanning::Events::PlaceholderSet, "hire-1", label: "Designer")
    plan(TeamPlanning::Events::DepartureWithdrawn, "hire-1")

    entry = status.statuses.find { it.facet == "departure" }
    assert_equal [ :plan_only, true ], [ entry.status, entry.staying ]
  end

  should "name every status it gives in the status tool's description" do
    TeamPlanning::Status::STATUSES.each { assert_includes Operations::TeamPlanning::Status.description, "'#{it}'" }
  end

  should "read a kind the Org Graph never moves plan only, never pending forever, with no source to go to" do
    plan(NoteSet, @ada.id, text: "Ask about the move")

    assert_equal [ [ :plan_only, nil, [] ] ], status.statuses.map { [ it.status, it.since, it.sources ] }
  end

  should "name each subject by its name today, a forgotten person a former member, and a subject only the plan holds not at all" do
    hire = SecureRandom.uuid_v7
    plan(TitleSet, @ada.id, title: "Senior Engineer")
    plan(TitleSet, @brook.id, title: "Lead Engineer")
    plan(TitleSet, @payments, title: "Squad")
    plan(TitleSet, hire, title: "Engineer")
    on(Time.utc(2026, 3, 10, 9)) { OrgGraph::StructureCommandHandler.new(actor: SYSTEM).rename_unit(@payments, "Payments Core", effective_on: "2026-03-10") }
    assert_equal [ "Ada Quill", "Brook Tamsin", "Payments Core", nil ], [ @ada.id, @brook.id, @payments, hire ].map { status.name_of(it) }

    as_tenant { @brook.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current) }
    assert_equal Person::FORMER_MEMBER, status.name_of(@brook.id)
  end

  should "refuse a scenario the plan doesn't have" do
    plan(TitleSet, @ada.id, title: "Senior Engineer")

    assert_raises(TeamPlanning::Error) { status(SecureRandom.uuid_v7) }
  end

  should "let a viewer read the status, and refuse anyone outside the plan, a tenant admin included" do
    viewer, outsider = as_tenant do
      Array.new(2) { create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant)) }
    end
    as_tenant { handler.add_member(@plan_id, viewer.person.id, role: "viewer") }

    assert_empty status(as: viewer).statuses
    assert_raises(Pundit::NotAuthorizedError) { status(as: outsider) }
  end

  should "refuse another tenant's admin" do
    other = create(:tenant)
    stranger = ActsAsTenant.with_tenant(other) { create(:tenant_user, tenant: other, role: :admin, person: create(:person, tenant: other)) }

    assert_raises(Pundit::NotAuthorizedError) { status(as: stranger) }
  end

  should "take an assignment's source from the unit it names, for someone the Org Graph lacks" do
    newcomer = sales = nil
    as_tenant do
      newcomer = create(:person, tenant: @tenant, name: "Cam Newell")
      sales = SecureRandom.uuid_v7
      department = SecureRandom.uuid_v7
      structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
      structure.define_taxonomy([ { level_id: department, name: "Department", provider: "hibob" }, { level_id: @squads, name: "Squad" } ],
                                effective_on: "2026-01-01")
      structure.create_unit(sales, "Sales", level_id: department, provider: "hibob", external_ref: "dept-1", effective_on: "2026-01-01")
    end
    plan(TeamPlanning::Events::AssignmentSet, newcomer.id, placements: [ { unit_id: sales, allocation: 1, role: "ENG" } ])

    on(TODAY) { assert_equal %w[hibob], status.statuses.find { it.subject_id == newcomer.id }.sources }
  end
end
