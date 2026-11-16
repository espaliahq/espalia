# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::ReportingAndDeparturesTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  BASE_ON = Date.new(2026, 3, 2)

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @payments = SecureRandom.uuid_v7
    level = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant, name: "Edie Marsh"))
      @other_admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant, name: "Vic Arden"))
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      @bo = create(:person, tenant: @tenant, name: "Bo Reyes")
      @cy = create(:person, tenant: @tenant, name: "Cy Moss")
      @engineer = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      @e2 = create(:framework_level, tenant: @tenant, role_id: @engineer.role_id, ordinal: 2, title: "Engineer II")
      structure.define_taxonomy([ { level_id: level, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: level, effective_on: "2026-01-01")
      [ @ada, @bo, @cy ].each do |person|
        handler.record_person(person.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed")
        handler.set_membership(person.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
      end
      handler.change_manager(@bo.id, @ada.id, **ESPALIA, effective_on: "2026-02-01")
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: BASE_ON.iso8601)[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @q1 = fork(relation: "then", name: "Q1", ends_on: "2026-06-30")
    @lean = fork(parent_id: @q1, relation: "instead", name: "Lean Q1")
    @q2 = fork(parent_id: @q1, relation: "then", name: "Q2", ends_on: "2026-09-30")
  end

  def call(operation, as: @editor, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def fork(**params) = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, **params)[:scenario_id]

  def report(scenario_id, person, as: @editor, **target)
    call(Operations::TeamPlanning::SetReportingLine, as:, plan_id: @plan_id, scenario_id:, person_id: person.id, **target)
  end

  def depart(scenario_id, person, as: @editor, **backfill)
    call(Operations::TeamPlanning::SetDeparture, as:, plan_id: @plan_id, scenario_id:, person_id: person.id, **backfill)
  end

  def map(scenario_id, as: @editor) = call(Operations::TeamPlanning::ScenarioMap, as:, plan_id: @plan_id, scenario_id:)

  def person_in(scenario_id, person) = map(scenario_id)[:people].find { it[:id] == person.id }

  def line_of(scenario_id, person) = person_in(scenario_id, person)&.slice(:manager_id, :manager_position_id)

  def resolved(scenario_id)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: @editor.user, tenant_user: @editor, person: @editor.person)
      TeamPlanning::Resolution.new(context:, plan: TeamPlanningPlan.find(@plan_id), scenario_id:).structure
    end
  end

  def open_position(scenario_id)
    call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id:, role_id: @engineer.role_id,
                                                level_id: @e2.level_id, unit_id: @payments, fte: 1, basis: "backfill")[:position_id]
  end

  def refusal(operation = Operations::TeamPlanning::SetReportingLine, as: @editor, scenario_id: @q1, **params)
    assert_raises(Operations::Base::ParameterError) { call(operation, as:, plan_id: @plan_id, scenario_id:, **params) }.message
  end

  should "open a leaver's share of their backfill, in the steps after they go, the day after they leave or when their step began" do
    dated, undated = open_position(@q1), open_position(@q1)
    depart(@q1, @ada, position_id: dated, leaves_on: "2026-05-19")
    depart(@q1, @bo, position_id: undated)
    opens = ->(scenario_id) { resolved(scenario_id).positions.to_h { [ it.id, [ it.opened_on, it.vacated ] ] } }
    vacated = ->(on) { [ TeamPlanning::Baseline::Vacated.new(fte: 1r, opens_on: on) ] }

    assert_equal({ dated => [ BASE_ON, [] ], undated => [ BASE_ON, [] ] }, opens.(@q1))
    assert_equal({ dated => [ BASE_ON, vacated.(Date.new(2026, 5, 20)) ], undated => [ BASE_ON, vacated.(BASE_ON) ] }, opens.(@q2))
  end

  should "read the baseline line from the Org Graph's manager fact, never from units" do
    assert_equal({ manager_id: @ada.id, manager_position_id: nil }, line_of(@plan_id, @bo))
    assert_equal({ manager_id: nil, manager_position_id: nil }, line_of(@plan_id, @cy))
    assert_equal "Ada Quill", map(@plan_id)[:names].fetch(@ada.id)
  end

  should "set a line in a step for the steps after it, and let an alternative override it" do
    assert_equal({ plan_id: @plan_id, scenario_id: @q1, person_id: @cy.id, manager_id: @bo.id, manager_position_id: nil },
                 report(@q1, @cy, manager_id: @bo.id))
    report(@lean, @cy, manager_id: @ada.id)

    assert_nil line_of(@plan_id, @cy)[:manager_id]
    assert_equal @bo.id, line_of(@q1, @cy)[:manager_id]
    assert_equal @bo.id, line_of(@q2, @cy)[:manager_id]
    assert_equal @ada.id, line_of(@lean, @cy)[:manager_id]
  end

  should "point a team at an open manager position, the span the seat carries" do
    seat = open_position(@q1)
    report(@q1, @bo, manager_position_id: seat)
    report(@q1, @cy, manager_position_id: seat)

    assert_equal({ manager_id: nil, manager_position_id: seat }, line_of(@q2, @bo))
    assert_equal [ @bo.id, @cy.id ].sort, resolved(@q2).reports_of(seat).sort
    assert_equal [ TeamPlanning::Baseline::Line.new(person_id: nil, position_id: seat) ], resolved(@q2).managers_above(@bo.id)
    assert_equal [ @bo.id ], resolved(@plan_id).reports_of(@ada.id)
  end

  should "walk up the lines and stop at a loop an ancestor's edit made" do
    report(@q1, @bo)
    report(@q2, @ada, manager_id: @bo.id)
    report(@q1, @bo, manager_id: @ada.id)

    lines = resolved(@q2).managers_above(@ada.id)
    assert_equal [ @bo.id, @ada.id ], lines.map(&:person_id)
  end

  should "refuse a loop through a manager position the person holds" do
    seat = open_position(@q1)
    report(@q1, @ada, manager_position_id: seat)
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @q1, person_id: @bo.id,
                                                  placements: [ { position_id: seat, allocation: 1 } ])

    assert_equal "That line makes a loop: the manager already reports up to this person", refusal(person_id: @bo.id, manager_id: @ada.id)
  end

  should "refuse a loop that starts at a manager position someone below holds" do
    seat = open_position(@q1)
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @q1, person_id: @bo.id,
                                                  placements: [ { position_id: seat, allocation: 1 } ])

    assert_equal "That line makes a loop: the manager already reports up to this person",
                 refusal(person_id: @ada.id, manager_position_id: seat)
  end

  should "walk a seat whose holders report to it once each, and accept a line from outside" do
    seat = open_position(@q1)
    [ @ada, @bo ].each { report(@q1, it, manager_position_id: seat) }
    [ @ada, @bo ].each do |holder|
      call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @q1, person_id: holder.id,
                                                    placements: [ { position_id: seat, allocation: 0.5 } ])
    end

    assert_equal seat, report(@q1, @cy, manager_position_id: seat)[:manager_position_id]
    assert_equal [ @ada.id, @bo.id, @cy.id ].sort, resolved(@q1).reports_of(seat).sort
  end

  should "refuse a self-line, a loop, both targets, a missing position and someone outside the tenant" do
    elsewhere = create(:person, tenant: create(:tenant))

    assert_equal "A person can't report to themself", refusal(person_id: @bo.id, manager_id: @bo.id)
    assert_equal "That line makes a loop: the manager already reports up to this person", refusal(person_id: @ada.id, manager_id: @bo.id)
    assert_equal "A person reports to a person or a position, not both",
                 refusal(person_id: @cy.id, manager_id: @ada.id, manager_position_id: open_position(@q1))
    assert_equal "This scenario has no such position", refusal(person_id: @cy.id, manager_position_id: open_position(@q2))
    assert_equal "No such manager", refusal(person_id: @cy.id, manager_id: elsewhere.id)
    assert_equal "No such person", refusal(person_id: elsewhere.id, manager_id: @ada.id)
    assert_equal "manager_id must be a UUID, got \"ada\"", refusal(person_id: @cy.id, manager_id: "ada")
  end

  should "keep a leaver on the map in their step, then take them off and leave the backfill standing alone" do
    seat = open_position(@q1)
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id,
                                                  placements: [ { position_id: seat, allocation: 1 } ])
    assert_equal({ plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, position_id: seat, leaves_on: nil }, depart(@q1, @ada, position_id: seat))

    [ @q1, @lean ].each do |step|
      leaver = person_in(step, @ada)
      assert leaver[:leaving], step
      assert_equal seat, leaver[:backfill_position_id]
      assert_nil leaver[:leaves_on]
      position = map(step)[:positions].find { it[:position_id] == seat }
      assert_equal [], position[:occupants], "a leaver never fills their backfill"
      assert_in_delta 1.0, position[:open_fte]
      assert_equal [ @ada.id ], position[:backfill_for_ids]
    end

    q2 = map(@q2)
    assert_nil q2[:people].find { it[:id] == @ada.id }
    assert_equal [ { person_id: @ada.id, position_id: seat } ], q2[:departed]
    assert_equal [ @ada.id ], q2[:positions].find { it[:position_id] == seat }[:backfill_for_ids]
    assert_not_includes q2[:unassigned_ids], @ada.id
    assert_equal "Ada Quill", q2[:names].fetch(@ada.id)
    assert_not person_in(@plan_id, @ada)[:leaving]
  end

  should "take a leaver off the map in the step after an alternative that inherited the departure" do
    depart(@q1, @cy)
    after_lean = fork(parent_id: @lean, relation: "then", name: "Q2 after lean", ends_on: "2026-09-30")

    assert person_in(@lean, @cy)[:leaving]
    assert_nil person_in(after_lean, @cy)
    assert_equal [ @cy.id ], map(after_lean)[:departed].map { it[:person_id] }
  end

  should "let a later step have the leaver stay, and the backfill name nobody" do
    seat = open_position(@q1)
    depart(@q1, @ada, position_id: seat)

    assert_equal({ plan_id: @plan_id, scenario_id: @q2, person_id: @ada.id, withdrawn: true },
                 call(Operations::TeamPlanning::WithdrawDeparture, plan_id: @plan_id, scenario_id: @q2, person_id: @ada.id))
    assert_not person_in(@q2, @ada)[:leaving]
    assert_equal [], map(@q2)[:positions].find { it[:position_id] == seat }[:backfill_for_ids]
    assert_equal "This scenario has nobody leaving by that id",
                 refusal(Operations::TeamPlanning::WithdrawDeparture, scenario_id: @plan_id, person_id: @ada.id)
    assert_equal "This scenario sets that departure itself: clear it to follow its parent",
                 refusal(Operations::TeamPlanning::WithdrawDeparture, scenario_id: @q1, person_id: @ada.id)
  end

  should "drop the link when the departure is cleared, and keep a pinned departure gone in a later step" do
    seat = open_position(@q1)
    depart(@q1, @ada, position_id: seat)
    call(Operations::TeamPlanning::PinChange, plan_id: @plan_id, scenario_id: @q2, subject_id: @ada.id, facet: "departure")
    assert_equal [ @ada.id ], map(@q2)[:departed].pluck(:person_id)

    call(Operations::TeamPlanning::ClearChange, plan_id: @plan_id, scenario_id: @q1, subject_id: @ada.id, facet: "departure")
    assert_not person_in(@q1, @ada)[:leaving]
    assert_equal [], map(@q1)[:positions].find { it[:position_id] == seat }[:backfill_for_ids]
  end

  should "pin that someone stays when nothing above has them leave, so a later departure above doesn't reach" do
    call(Operations::TeamPlanning::PinChange, plan_id: @plan_id, scenario_id: @q2, subject_id: @ada.id, facet: "departure")
    depart(@q1, @ada)

    assert person_in(@q1, @ada)[:leaving]
    assert_not person_in(@q2, @ada)[:leaving]
  end

  should "name a forgotten leaver as a former member on their backfill" do
    seat = open_position(@q1)
    depart(@q1, @ada, position_id: seat)
    ActsAsTenant.with_tenant(@tenant) { @ada.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current) }

    positions = call(Operations::TeamPlanning::Positions, plan_id: @plan_id, scenario_id: @q2)
    assert_equal [ @ada.id ], positions[:positions].first[:backfill_for_ids]
    assert_equal Person::FORMER_MEMBER, positions[:names].fetch(@ada.id)
  end

  should "hold a leaving date within the step, and carry it with them once they've gone" do
    seat = open_position(@q1)
    assert_equal "2026-04-30", depart(@q1, @ada, position_id: seat, leaves_on: "2026-04-30")[:leaves_on]
    assert_equal [ true, "2026-04-30" ], person_in(@q1, @ada).values_at(:leaving, :leaves_on), "the step they leave in shows when"
    call(Operations::TeamPlanning::PinChange, plan_id: @plan_id, scenario_id: @q2, subject_id: @ada.id, facet: "departure")

    depart(@q1, @cy)

    assert_equal [ { person_id: @ada.id, position_id: seat, leaves_on: "2026-04-30" }, { person_id: @cy.id, position_id: nil } ],
                 map(@q2)[:departed].sort_by { it[:person_id] == @ada.id ? 0 : 1 }
  end

  should "refuse a leaving date outside the step, in the baseline, or that isn't a date" do
    assert_equal "The leaving date must fall within the scenario's period, 2026-03-02 to 2026-06-30",
                 refusal(Operations::TeamPlanning::SetDeparture, person_id: @ada.id, leaves_on: "2026-07-01")
    assert_equal "The leaving date must fall within the scenario's period, 2026-07-01 to 2026-09-30",
                 refusal(Operations::TeamPlanning::SetDeparture, scenario_id: @q2, person_id: @ada.id, leaves_on: "2026-06-30")
    q3 = fork(parent_id: @q2, relation: "then", name: "Q3 onwards")
    assert_equal "The leaving date must fall on or after the scenario's start, 2026-10-01",
                 refusal(Operations::TeamPlanning::SetDeparture, scenario_id: q3, person_id: @ada.id, leaves_on: "2026-09-30")
    assert_equal "2030-01-31", depart(q3, @ada, leaves_on: "2030-01-31")[:leaves_on], "a step with no end date takes any later day"
    assert_equal "The baseline has no period, so a departure in it takes no leaving date",
                 refusal(Operations::TeamPlanning::SetDeparture, scenario_id: @plan_id, person_id: @ada.id, leaves_on: "2026-03-02")
    assert_equal "A leaving date must be a date, such as 2027-03-31",
                 refusal(Operations::TeamPlanning::SetDeparture, person_id: @ada.id, leaves_on: "end of April")
  end

  should "refuse a departure's missing position, and someone outside the tenant" do
    elsewhere = create(:person, tenant: create(:tenant))

    assert_equal "This scenario has no such position",
                 refusal(Operations::TeamPlanning::SetDeparture, person_id: @ada.id, position_id: open_position(@q2))
    assert_equal "No such person", refusal(Operations::TeamPlanning::SetDeparture, person_id: elsewhere.id)
  end

  should "read as missing to an admin outside the plan, and refuse a viewer's writes" do
    [ @other_admin, @viewer ].each do |as|
      assert_equal "No such plan", refusal(as:, person_id: @cy.id, manager_id: @cy.id)
      assert_equal "No such plan", refusal(Operations::TeamPlanning::SetDeparture, as:, person_id: @ada.id)
      assert_equal "No such plan", refusal(Operations::TeamPlanning::WithdrawDeparture, as:, person_id: @ada.id)
    end
  end
end
