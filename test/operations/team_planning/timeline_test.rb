# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::TimelineTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @payments = SecureRandom.uuid_v7
    @growth = SecureRandom.uuid_v7
    @squad = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant, name: "Edie Marsh"))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant, name: "Vic Arden"))
      @outsider = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      @bo = create(:person, tenant: @tenant, name: "Bo Reyes")
      @cy = create(:person, tenant: @tenant, name: "Cy Lowe")
      @engineer = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      @e2 = create(:framework_level, tenant: @tenant, role_id: @engineer.role_id, ordinal: 2, title: "Engineer II")
      structure.define_taxonomy([ { level_id: @squad, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: @squad, effective_on: "2026-01-01")
      structure.create_unit(@growth, "Growth", level_id: @squad, effective_on: "2026-01-01")
      [ @ada, @bo, @cy ].each do |person|
        handler.record_person(person.id, **ESPALIA, effective_on: "2026-01-15", employment_status: "employed")
        handler.set_membership(person.id, @payments, **ESPALIA, effective_on: "2026-01-15", allocation: 1.0)
      end
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @q1 = fork(relation: "then", name: "Q1", ends_on: "2026-06-30")
    @q2 = fork(parent_id: @q1, relation: "then", name: "Q2", ends_on: "2026-09-30")
  end

  def call(operation, as: @editor, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def fork(**params) = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, **params)[:scenario_id]

  def timeline(scenario_id = @q2, as: @editor) = call(Operations::TeamPlanning::Timeline, as:, plan_id: @plan_id, scenario_id:)

  def assign(scenario_id, person, *placements)
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id:, person_id: person.id, placements:)
  end

  def unit(scenario_id, **params) = call(Operations::TeamPlanning::SetUnit, plan_id: @plan_id, scenario_id:, **params)[:unit_id]

  def open_position(scenario_id, unit_id: @payments, basis: "new")
    call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id:, role_id: @engineer.role_id,
                                                level_id: @e2.level_id, unit_id:, fte: 1, basis:)[:position_id]
  end

  def hire(scenario_id, label, seat, allocation: 1)
    id = call(Operations::TeamPlanning::SetPlaceholderHire, plan_id: @plan_id, scenario_id:, label:)[:placeholder_id]
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id:, person_id: id, placements: [ { position_id: seat, allocation: } ])
    id
  end

  def leave(scenario_id, person, position_id: nil)
    call(Operations::TeamPlanning::SetDeparture, plan_id: @plan_id, scenario_id:, person_id: person.id, position_id:)
  end

  def lane(result, id) = result[:lanes].find { it[:lane_id] == id }

  def block(result, id) = result[:blocks].find { it[:block_id] == id }

  def spans(lane) = lane[:bars].map { [ it[:kind], it[:subject_id], it[:unit_id], it[:from], it[:to] ] }

  should "lay out the path from the baseline to a scenario, one column per step, with the alternatives at each" do
    lean = fork(parent_id: @q1, relation: "instead", name: "Lean Q1")
    later = fork(parent_id: @q2, relation: "then", name: "Q3", ends_on: "2026-12-31")
    result = timeline

    assert_equal [ @plan_id, @q1, @q2 ], result[:columns].pluck(:scenario_id)
    assert_equal [ "Q1", "2026-03-02", "2026-06-30", [ lean ] ], result[:columns][1].values_at(:name, :starts_on, :ends_on, :alternative_ids)
    assert_equal [ [], [] ], [ result[:columns][0][:alternative_ids], result[:columns][2][:alternative_ids] ]
    assert_equal [ later ], result[:next_ids]
    assert_equal [ @plan_id, lean ], timeline(lean)[:columns].pluck(:scenario_id)
  end

  should "list in each column the places, positions and departures that step itself changes, and nothing else" do
    assign(@q1, @ada, { unit_id: @growth, allocation: 1 })
    seat = open_position(@q2)
    leave(@q2, @bo)
    call(Operations::TeamPlanning::SetPlannedLevel, plan_id: @plan_id, scenario_id: @q2, person_id: @cy.id, level: "4")

    assert_equal [ [], [ { subject_id: @ada.id, facet: "assignment" } ],
                   [ { subject_id: @bo.id, facet: "departure" }, { subject_id: seat, facet: "position" } ].sort_by { it[:subject_id] } ],
                 timeline[:columns].pluck(:movable)
  end

  should "keep a renamed unit as one block, continue it into a one-to-one successor, and link a split" do
    unit(@q1, unit_id: @payments, name: "Billing")
    core = unit(@q2, name: "Core", level_id: @squad)
    call(Operations::TeamPlanning::SetUnitSuccession, plan_id: @plan_id, scenario_id: @q2, predecessor_ids: [ @growth ], successor_ids: [ core ])
    cards, wallets = %w[Cards Wallets].map { unit(@q2, name: it, level_id: @squad) }
    call(Operations::TeamPlanning::SetUnitSuccession, plan_id: @plan_id, scenario_id: @q2, predecessor_ids: [ @payments ],
                                                      successor_ids: [ cards, wallets ])
    result = timeline

    assert_equal [ "Payments", "Billing", nil ], block(result, @payments)[:units].map { it&.dig(:name) }
    assert_equal [ @growth, @growth, core ], block(result, @growth)[:units].pluck(:unit_id)
    assert_empty block(result, @growth)[:continues_from_ids]
    assert_nil block(result, core)
    assert_equal [ nil, nil, cards ], block(result, cards)[:units].map { it&.dig(:unit_id) }
    assert_equal [ @payments ], block(result, cards)[:continues_from_ids]
  end

  should "keep a unit that absorbs another existing one as its own block, carrying on from it" do
    call(Operations::TeamPlanning::SetUnitSuccession, plan_id: @plan_id, scenario_id: @q2, predecessor_ids: [ @growth ], successor_ids: [ @payments ])
    result = timeline

    assert_equal [ @growth, @growth, nil ], block(result, @growth)[:units].map { it&.dig(:unit_id) }
    assert_equal [ @payments ] * 3, block(result, @payments)[:units].pluck(:unit_id)
    assert_equal [ @growth ], block(result, @payments)[:continues_from_ids]
  end

  should "keep one lane for a person in two places, with a bar for each and no move" do
    assign(@q1, @ada, { unit_id: @payments, allocation: 0.5 }, { unit_id: @growth, allocation: 0.5 })
    ada = lane(timeline, @ada.id)

    assert_equal [ [ "person", @ada.id, @payments, 0, 0 ], [ "person", @ada.id, @growth, 1, 2 ], [ "person", @ada.id, @payments, 1, 2 ] ],
                 spans(ada).sort_by { [ it[3], it[2] == @growth ? 0 : 1 ] }
    assert_equal [ 1.0, 0.5, 0.5 ], ada[:bars].map { it[:allocation].to_f }
    assert_empty ada[:moves]
  end

  should "name where a person left and joined, Unassigned included, without ending their lane" do
    assign(@q1, @bo, { unit_id: @growth, allocation: 1 })
    assign(@q2, @bo)
    result = timeline
    bo = lane(result, @bo.id)

    assert_equal [ [ "person", @bo.id, @payments, 0, 0 ], [ "person", @bo.id, @growth, 1, 1 ], [ "person", @bo.id, nil, 2, 2 ] ], spans(bo)
    assert_equal [ { person_id: @bo.id, after: 0, left_unit_ids: [ @payments ], joined_unit_ids: [ @growth ] },
                   { person_id: @bo.id, after: 1, left_unit_ids: [ @growth ], joined_unit_ids: [ nil ] } ], bo[:moves]
    assert_equal [ @bo.id ], result[:unassigned_lane_ids]
    assert_includes block(result, @growth)[:lane_ids], @bo.id
  end

  should "not count carrying on into a unit's successor as a move" do
    core = unit(@q2, name: "Core", level_id: @squad)
    call(Operations::TeamPlanning::SetUnitSuccession, plan_id: @plan_id, scenario_id: @q2, predecessor_ids: [ @payments ], successor_ids: [ core ])
    assign(@q2, @ada, { unit_id: core, allocation: 1 })
    ada = lane(timeline, @ada.id)

    assert_equal [ [ "person", @ada.id, @payments, 0, 1 ], [ "person", @ada.id, core, 2, 2 ] ], spans(ada)
    assert_empty ada[:moves]
  end

  should "end a leaver's lane where they leave and carry their backfill on in it, but give a new position its own" do
    backfill = open_position(@q1, basis: "backfill")
    leave(@q1, @cy, position_id: backfill)
    fresh = open_position(@q2, unit_id: @growth)
    result = timeline
    cy = lane(result, @cy.id)

    assert_equal [ [ "person", @cy.id, @payments, 0, 1 ], [ "position", backfill, @payments, 1, 2 ] ], spans(cy)
    assert_equal [ { person_id: @cy.id, column: 1, position_id: backfill } ], cy[:departures]
    assert_equal @cy.id, cy[:bars].last[:replaces_id]
    assert_nil lane(result, backfill)
    assert_equal [ [ "position", fresh, @growth, 2, 2 ] ], spans(lane(result, fresh))
    assert_equal "Software Engineer", result[:positions][fresh][:role_name]
  end

  should "give each position where its hiring stood in every column" do
    seat = open_position(@q1)
    call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @q2, position_id: seat, role_id: @engineer.role_id,
                                                level_id: @e2.level_id, unit_id: @payments, fte: 1, basis: "new", hiring_status: "on_hold")

    assert_equal [ nil, { hiring_status: "not_started", target_start: nil }, { hiring_status: "on_hold", target_start: nil } ],
                 timeline[:positions][seat][:hiring]
  end

  should "carry a hire on in the lane of the position they fill" do
    seat = open_position(@q1, unit_id: @growth)
    hire = hire(@q2, "Growth engineer", seat)
    result = timeline

    assert_equal [ [ "position", seat, @growth, 1, 1 ], [ "person", hire, @growth, 2, 2 ] ], spans(lane(result, seat))
    assert_nil lane(result, hire)
    assert_equal "Growth engineer", result[:names][hire]
  end

  should "give a seat's lane to one hire, however many it takes" do
    seat = open_position(@q1, unit_id: @growth)
    hires = [ hire(@q2, "First", seat, allocation: 0.5), hire(@q2, "Second", seat, allocation: 0.5) ]
    result = timeline

    assert_equal 1, lane(result, seat)[:bars].count { it[:kind] == "person" }
    assert_equal 1, hires.count { lane(result, it) }
  end

  should "run a backfill shared by two leavers in the lane of the one it replaces" do
    backfill = open_position(@q1, basis: "backfill")
    [ @ada, @bo ].each { leave(@q1, it, position_id: backfill) }
    result = timeline
    owner = result[:lanes].find { |lane| lane[:bars].any? { it[:subject_id] == backfill } }

    assert_equal owner[:lane_id], owner[:bars].find { it[:subject_id] == backfill }[:replaces_id]
  end

  should "order blocks as they first appear and lanes in a block by when they arrive, people first, then by name" do
    risk = unit(@q1, name: "Aardvarks", level_id: @squad)
    assign(@q1, @cy, { unit_id: risk, allocation: 1 })
    seat = open_position(@q1)
    result = timeline

    assert_equal [ @growth, @payments, risk ], result[:blocks].pluck(:block_id)
    assert_equal [ @ada.id, @bo.id, @cy.id, seat ], block(result, @payments)[:lane_ids]
    assert_equal [ @cy.id ], block(result, risk)[:lane_ids]
    assert_equal [ @ada.id, @bo.id, @cy.id, seat ], result[:lanes].pluck(:lane_id)
  end

  should "keep a forgotten person's lane, by id, with no name" do
    ActsAsTenant.with_tenant(@tenant) { @bo.update_columns(forgotten_at: Time.current, name: Person::FORMER_MEMBER) }
    result = timeline

    assert lane(result, @bo.id)
    assert_equal Person::FORMER_MEMBER, result[:names][@bo.id]
    assert_not_includes result.to_json, "Bo Reyes"
  end

  should "read the Org Graph once, whatever the path's length" do
    reads = 0
    as_of = OrgGraph::AsOf.method(:new)
    OrgGraph::AsOf.stub(:new, ->(**args) { reads += 1; as_of.call(**args) }) { timeline }

    assert_equal 1, reads
  end

  should "open to a viewer and read as an unknown plan to anyone outside it" do
    assert_equal [ @plan_id, @q1, @q2 ], timeline(as: @viewer)[:columns].pluck(:scenario_id)
    error = assert_raises(Operations::Base::ParameterError) { timeline(as: @outsider) }
    assert_equal "No such plan", error.message
  end
  def walk(*counts) = %i[opening hires transfers_in departures transfers_out closing].zip(counts).to_h

  def assert_walks_reconcile(result)
    walks = [ result[:walk], result[:unassigned_walk], *result[:blocks].pluck(:walk) ]
    walks.each do |columns|
      columns.each_cons(2) do |before, after|
        assert_equal before[:closing], after[:opening]
        assert_equal after[:closing], after[:opening] + after[:hires] + after[:transfers_in] - after[:departures] - after[:transfers_out]
      end
    end
  end

  should "walk the heads of the plan and each unit, counting a person in two units once in each" do
    assign(@q1, @ada, { unit_id: @payments, allocation: 0.5 }, { unit_id: @growth, allocation: 0.5 })
    hire(@q1, "Growth engineer", open_position(@q1, unit_id: @growth))
    leave(@q1, @bo)
    assign(@q2, @cy, { unit_id: @growth, allocation: 1 })
    result = timeline

    assert_equal [ walk(nil, nil, nil, nil, nil, 3), walk(3, 1, 0, 1, 0, 3), walk(3, 0, 0, 0, 0, 3) ], result[:walk]
    assert_equal [ walk(nil, nil, nil, nil, nil, 3), walk(3, 0, 0, 1, 0, 2), walk(2, 0, 0, 0, 1, 1) ], block(result, @payments)[:walk]
    assert_equal [ walk(nil, nil, nil, nil, nil, 0), walk(0, 1, 1, 0, 0, 2), walk(2, 0, 1, 0, 0, 3) ], block(result, @growth)[:walk]
    assert_equal [ 0, 0, 0 ], result[:unassigned_walk].pluck(:closing)
    assert_walks_reconcile(result)
  end

  should "count a move across a scoped plan's edge as a transfer, and a half-outside person as one head" do
    dee = ActsAsTenant.with_tenant(@tenant) do
      create(:person, tenant: @tenant, name: "Dee Park").tap do |person|
        handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        handler.record_person(person.id, **ESPALIA, effective_on: "2026-01-15", employment_status: "employed")
        handler.set_membership(person.id, @growth, **ESPALIA, effective_on: "2026-01-15", allocation: 1.0)
      end
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Payments", base_on: "2026-03-02", unit_ids: [ @payments ])[:plan_id]
    h1 = fork(relation: "then", name: "H1", ends_on: "2026-06-30")
    assign(h1, @ada, { unit_id: @growth, allocation: 1 })
    call(Operations::TeamPlanning::SetAssignment, plan_id: @plan_id, scenario_id: h1, person_id: dee.id, placements: [ { unit_id: @payments, allocation: 1 } ])
    assign(h1, @bo, { unit_id: @payments, allocation: 0.5 }, { unit_id: @growth, allocation: 0.5 })
    hire(h1, "Payments engineer", open_position(h1))
    result = timeline(h1)

    assert_equal [ walk(nil, nil, nil, nil, nil, 3), walk(3, 1, 1, 0, 1, 4) ], result[:walk]
    assert_equal [ walk(nil, nil, nil, nil, nil, 3), walk(3, 1, 1, 0, 1, 4) ], block(result, @payments)[:walk]
    assert_nil block(result, @growth)
    assert_walks_reconcile(result)
  end

  should "count a leaver as a departure though the same step also takes them outside a scoped plan" do
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Payments", base_on: "2026-03-02", unit_ids: [ @payments ])[:plan_id]
    h1 = fork(relation: "then", name: "H1", ends_on: "2026-06-30")
    leave(h1, @bo)
    assign(h1, @bo, { unit_id: @growth, allocation: 1 })
    result = timeline(h1)

    assert_equal walk(3, 0, 0, 1, 0, 2), result[:walk].last
    assert_equal walk(3, 0, 0, 1, 0, 2), block(result, @payments)[:walk].last
    assert_walks_reconcile(result)
  end
end
