# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class TeamPlanning::Projections::HistoryTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  CAP = "rule:test_headcount_cap"

  class HeadcountCap < TeamPlanning::RuleKind
    def self.rule_name = "test_headcount_cap"
    def self.description = "The most people a unit may hold"
    def self.default = { "cap" => 10 }
  end

  setup do
    TeamPlanning::RuleKinds.register(HeadcountCap)
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @person = create(:person, tenant: @tenant)
    user = create(:user)
    tenant_user = create(:tenant_user, tenant: @tenant, user:, person: @person, role: :admin)
    @handler = TeamPlanning::CommandHandler.new(actor: AuthorizationContext.new(user:, tenant_user:, person: @person))
    @plan_id = SecureRandom.uuid_v7
    @handler.create_plan(@plan_id, name: "Next year", base_on: "2027-01-01")
    @q1 = fork(@plan_id, "then", "Q1", ends_on: "2027-03-31")
    @lean = fork(@q1, "instead", "Lean Q1")
  end

  teardown do
    ActsAsTenant.current_tenant = nil
    TeamPlanning::RuleKinds.unregister(HeadcountCap)
  end

  def fork(parent_id, relation, name, ends_on: nil)
    SecureRandom.uuid_v7.tap { @handler.fork_scenario(@plan_id, it, parent_id:, relation:, name:, ends_on:) }
  end

  def set_cap(scenario_id, cap, note: nil)
    @handler.set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id:, subject_id: @plan_id,
                                                                 end_state: { rule: "test_headcount_cap", value: { cap: } }, note:)
  end

  def set_level(scenario_id, level)
    @handler.set_change(@plan_id, TeamPlanning::Events::LevelSet, scenario_id:, subject_id: @person.id, end_state: { level: })
  end

  def split(scenario_id, *event_ids)
    SecureRandom.uuid_v7.tap { @handler.split_scenario(@plan_id, scenario_id, agreed_id: it, name: "Agreed", event_ids:) }
  end

  def history(scenario_id) = TeamPlanningHistoryEntry.where(scenario_id:).order(:position)

  should "record each change, pin and clear in order, with its facet and who made it" do
    set_cap(@q1, 8)
    @handler.pin_change(@plan_id, scenario_id: @lean, subject_id: @plan_id, facet: CAP)
    @handler.clear_change(@plan_id, scenario_id: @lean, subject_id: @plan_id, facet: CAP)

    assert_equal [ [ 1, "set", CAP, @person.id ] ], history(@q1).pluck(:position, :action, :facet, :actor_id)
    assert_equal [ [ 1, "pin", @q1 ], [ 2, "clear", nil ] ], history(@lean).pluck(:position, :action, :pinned_from_scenario_id)
    assert_equal({ "rule" => "test_headcount_cap", "value" => { "cap" => 8 } }, history(@q1).sole.end_state)
  end

  should "keep the note a change or pin was made with, sealed under the plan's key" do
    set_cap(@q1, 8, note: "Hiring freeze until the spring")
    @handler.pin_change(@plan_id, scenario_id: @lean, subject_id: @plan_id, facet: CAP, note: "Lean keeps the freeze")

    assert_equal [ "Hiring freeze until the spring", "Lean keeps the freeze" ], [ @q1, @lean ].map { history(it).sole.note.reveal }

    PlanKeyStore.new.destroy_plan(@plan_id)
    assert [ @q1, @lean ].all? { history(it).sole.reload.note.removed? }
  end

  should "keep an undone entry, marked with who undid it, and unmark it on redo" do
    set_cap(@q1, 8)
    undone = @handler.undo_change(@plan_id, scenario_id: @q1)

    set, undo = history(@q1).to_a
    assert_equal [ undone, @person.id ], [ set.id, set.undone_by_id ]
    assert_not_nil set.undone_at
    assert_equal [ "undo", undone ], [ undo.action, undo.reverses_event_id ]

    @handler.redo_change(@plan_id, scenario_id: @q1)
    assert_equal [ [ "set", false ], [ "undo", false ], [ "redo", false ] ], history(@q1).map { [ it.action, it.undone? ] }
  end

  should "keep each archive and restore in the baseline's history, with who did it" do
    @handler.archive_plan(@plan_id)
    @handler.restore_plan(@plan_id)

    assert_equal [ [ "archive", @person.id ], [ "restore", @person.id ] ], history(@plan_id).pluck(:action, :actor_id)
  end

  should "drop a removed scenario's history, and every entry of a deleted plan" do
    set_cap(@q1, 8)
    set_cap(@lean, 5)

    @handler.remove_scenario(@plan_id, @lean)
    assert_equal [ @q1 ], TeamPlanningHistoryEntry.distinct.pluck(:scenario_id)

    @handler.delete_plan(@plan_id)
    assert_empty TeamPlanningHistoryEntry.all
  end

  should "move every entry of a split's subjects and facets to the agreed part, undo included, in their order" do
    set_cap(@q1, 8)
    set_level(@q1, "4")
    set_cap(@q1, 6)
    @handler.undo_change(@plan_id, scenario_id: @q1)
    capped = history(@q1).first.id

    agreed = split(@q1, capped)

    assert_equal [ [ 1, "set", capped ], [ 2, "set", nil ], [ 3, "undo", nil ] ],
                 history(agreed).pluck(:position, :action, :id).map { |position, action, id| [ position, action, (id if id == capped) ] }
    assert_equal [ [ 2, "level" ] ], history(@q1).pluck(:position, :facet)
  end

  def place(scenario_id)
    @handler.set_change(@plan_id, TeamPlanning::Events::AssignmentSet, scenario_id:, subject_id: @person.id,
                                                                       end_state: { placements: [ { unit_id: @plan_id, allocation: 1.0 } ] })
  end

  def move_later(scenario_id) = @handler.move_change(@plan_id, scenario_id:, subject_id: @person.id, facet: "assignment", direction: "later")

  should "take a moved change's entries to the step it reached, record the move there, and bring them back on undo" do
    q2 = fork(@q1, "then", "Q2", ends_on: "2027-06-30")
    place(@q1)
    placed = history(@q1).sole.id
    move_later(@q1)

    assert_empty history(@q1)
    assert_equal [ [ placed, "set" ], [ nil, "move" ] ], history(q2).pluck(:id, :action).map { |id, action| [ (id if id == placed), action ] }
    assert_equal({ "from_scenario_id" => @q1, "direction" => "later" }, history(q2).last.end_state)

    @handler.undo_change(@plan_id, scenario_id: q2)
    assert_equal [ placed ], history(@q1).pluck(:id)
    assert_equal [ [ "move", @person.id ], [ "undo", nil ] ], history(q2).pluck(:action, :undone_by_id)

    @handler.redo_change(@plan_id, scenario_id: q2)
    assert_empty history(@q1)
    assert_equal %w[set move undo redo], history(q2).pluck(:action)
  end

  should "take a moved change's notes, undos and redos with it, and on undo put it back in its place" do
    q2 = fork(@q1, "then", "Q2", ends_on: "2027-06-30")
    place(@q1)
    placed = history(@q1).sole.id
    @handler.note_change(@plan_id, scenario_id: @q1, event_id: placed, note: "Starts in March")
    @handler.undo_change(@plan_id, scenario_id: @q1)
    @handler.redo_change(@plan_id, scenario_id: @q1)
    set_cap(@q1, 8)
    move_later(@q1)

    assert_equal %w[set], history(@q1).pluck(:action)
    assert_equal %w[set note undo redo move], history(q2).pluck(:action)

    @handler.undo_change(@plan_id, scenario_id: q2)
    assert_equal [ [ placed, "set" ], [ placed, "note" ], [ placed, "undo" ], [ placed, "redo" ], [ nil, "set" ] ],
                 history(@q1).pluck(:id, :action, :noted_event_id, :reverses_event_id).map { |id, action, noted, reverses| [ [ id, noted, reverses ].include?(placed) ? placed : nil, action ] }
  end

  should "record a step's new dates in its history, with its period before and after" do
    @handler.set_scenario_period(@plan_id, @q1, starts_on: "2027-02-01", ends_on: "2027-04-30")

    entry = history(@q1).sole
    assert_equal [ "dates", @person.id ], [ entry.action, entry.actor_id ]
    assert_equal({ "starts_on" => "2027-02-01", "ends_on" => "2027-04-30", "previous_starts_on" => "2027-01-01",
                   "previous_ends_on" => "2027-03-31" }, entry.end_state)
  end

  should "record dates written before a first step could move its start, without a previous start" do
    event = TeamPlanning::Events::ScenarioPeriodSet.new(
      data: { plan_id: @plan_id, scenario_id: @q1, starts_on: "2027-01-01", ends_on: "2027-04-30", previous_ends_on: "2027-03-31",
              set_by_id: @person.id },
      metadata: { tenant_id: @tenant.id, timestamp: Time.current }
    )
    TeamPlanning::Projections::History.new.call(event)

    assert_equal({ "starts_on" => "2027-01-01", "ends_on" => "2027-04-30", "previous_ends_on" => "2027-03-31" }, history(@q1).sole.end_state)
  end

  context "rebuild contract" do
    should "reset! + replay produce identical read-model state, including the stable ids" do
      q2 = fork(@q1, "then", "Q2", ends_on: "2027-06-30")
      place(@q1)
      move_later(@q1)
      @handler.undo_change(@plan_id, scenario_id: q2)
      @handler.redo_change(@plan_id, scenario_id: q2)
      set_cap(@q1, 8, note: "Hiring freeze until the spring")
      set_cap(@q1, 6)
      @handler.undo_change(@plan_id, scenario_id: @q1)
      @handler.note_change(@plan_id, scenario_id: @q1, event_id: history(@q1).first.id, note: "Until the spring")
      @handler.pin_change(@plan_id, scenario_id: @lean, subject_id: @plan_id, facet: CAP)
      @handler.redo_change(@plan_id, scenario_id: @q1)
      @handler.set_change(@plan_id, TeamPlanning::Events::LevelSet, scenario_id: @q1, subject_id: @person.id,
                                                                    end_state: { level: "4" }, note: "Ready since the launch")
      @handler.note_change(@plan_id, scenario_id: @q1, event_id: history(@q1).last.id, note: "Ready, and asked for it")
      split(@q1, history(@q1).last.noted_event_id)
      @handler.set_scenario_period(@plan_id, q2, ends_on: "2027-07-31")

      before = snapshot_read_models(TeamPlanning::Projections::History, @tenant)
      assert_equal 13, before[:history].size

      TeamPlanning::Projections::History.reset!(tenant: @tenant)
      assert_equal 0, TeamPlanningHistoryEntry.count
      Projections::Replayer.replay(projection_class: TeamPlanning::Projections::History, tenant: @tenant)

      assert_equal before, snapshot_read_models(TeamPlanning::Projections::History, @tenant)
    end
  end

  should "keep one tenant's history out of another's" do
    set_cap(@q1, 8)
    ActsAsTenant.with_tenant(create(:tenant)) { assert_empty TeamPlanningHistoryEntry.all }
  end
end
