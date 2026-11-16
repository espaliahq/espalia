# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class TeamPlanning::Projections::OverridesTest < ActiveSupport::TestCase
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

  def overrides = TeamPlanningOverride.order(:scenario_id).pluck(:scenario_id, :facet, :pinned, :end_state)

  should "keep one row per subject and facet, from the last change set there" do
    set_cap(@q1, 8)
    set_cap(@q1, 6)

    row = TeamPlanningOverride.sole
    assert_equal [ @q1, CAP, "TeamPlanning::Events::RuleSet", false, @person.id ],
                 [ row.scenario_id, row.facet, row.kind, row.pinned, row.set_by_id ]
    assert_equal({ "rule" => "test_headcount_cap", "value" => { "cap" => 6 } }, row.end_state)
  end

  should "record a pin and where it came from, and drop a row on a clear" do
    set_cap(@q1, 8)
    @handler.pin_change(@plan_id, scenario_id: @lean, subject_id: @plan_id, facet: CAP)

    pin = TeamPlanningOverride.find_by(scenario_id: @lean)
    assert_equal [ true, @q1, TeamPlanningOverride.find_by(scenario_id: @q1).event_id ],
                 [ pin.pinned, pin.pinned_from_scenario_id, pin.pinned_from_event_id ]

    @handler.clear_change(@plan_id, scenario_id: @lean, subject_id: @plan_id, facet: CAP)
    assert_equal [ @q1 ], overrides.map(&:first)
  end

  should "keep one row for a facet two kinds share, of whichever kind came last" do
    position = { subject_id: SecureRandom.uuid_v7 }
    @handler.set_change(@plan_id, TeamPlanning::Events::PositionSet, scenario_id: @q1, **position,
                                                                     end_state: { role_id: "r", level_id: "l", unit_id: "u", fte: 1, basis: "new" })
    @handler.set_change(@plan_id, TeamPlanning::Events::PositionClosed, scenario_id: @q1, **position)

    assert_equal [ [ "position", "TeamPlanning::Events::PositionClosed", {} ] ], TeamPlanningOverride.pluck(:facet, :kind, :end_state)

    @handler.pin_change(@plan_id, scenario_id: @lean, **position, facet: "position")
    assert_equal "TeamPlanning::Events::PositionClosed", TeamPlanningOverride.find_by(scenario_id: @lean).kind

    @handler.clear_change(@plan_id, scenario_id: @q1, **position, facet: "position")
    assert_equal [ @lean ], overrides.map(&:first)
  end

  should "bring back the change before an undone one, and the undone one on redo" do
    set_cap(@q1, 8)
    set_cap(@q1, 6)
    @handler.undo_change(@plan_id, scenario_id: @q1)
    assert_equal({ "rule" => "test_headcount_cap", "value" => { "cap" => 8 } }, TeamPlanningOverride.sole.end_state)

    @handler.redo_change(@plan_id, scenario_id: @q1)
    assert_equal({ "rule" => "test_headcount_cap", "value" => { "cap" => 6 } }, TeamPlanningOverride.sole.end_state)
  end

  should "keep each change's note, sealed, and bring it back with its change on undo and redo" do
    set_cap(@q1, 8, note: "Hiring freeze until the spring")
    set_cap(@q1, 6)
    assert_nil TeamPlanningOverride.sole.note

    @handler.undo_change(@plan_id, scenario_id: @q1)
    assert_equal "Hiring freeze until the spring", TeamPlanningOverride.sole.note.reveal

    @handler.redo_change(@plan_id, scenario_id: @q1)
    assert_nil TeamPlanningOverride.sole.note
  end

  should "drop the row when the only change is undone, and restore a cleared one when the clear is undone" do
    set_cap(@lean, 5)
    @handler.undo_change(@plan_id, scenario_id: @lean)
    assert_empty overrides

    @handler.redo_change(@plan_id, scenario_id: @lean)
    @handler.clear_change(@plan_id, scenario_id: @lean, subject_id: @plan_id, facet: CAP)
    assert_empty overrides
    @handler.undo_change(@plan_id, scenario_id: @lean)
    assert_equal [ [ @lean, CAP, false, { "rule" => "test_headcount_cap", "value" => { "cap" => 5 } } ] ], overrides
  end

  should "restore a pin's row, pin fields and all, when what replaced it is undone" do
    set_cap(@q1, 8)
    @handler.pin_change(@plan_id, scenario_id: @lean, subject_id: @plan_id, facet: CAP)
    pinned = TeamPlanningOverride.find_by(scenario_id: @lean).attributes.slice("event_id", "pinned", "pinned_from_event_id")
    set_cap(@lean, 3)

    @handler.undo_change(@plan_id, scenario_id: @lean)
    assert_equal pinned, TeamPlanningOverride.find_by(scenario_id: @lean).attributes.slice("event_id", "pinned", "pinned_from_event_id")
  end

  should "drop a removed scenario's rows, and every row of a deleted plan" do
    set_cap(@q1, 8)
    set_cap(@lean, 5)

    @handler.remove_scenario(@plan_id, @lean)
    assert_equal [ @q1 ], overrides.map(&:first)

    @handler.delete_plan(@plan_id)
    assert_empty overrides
  end

  should "move the rows of a split's subjects and facets to the agreed part, and leave the rest" do
    set_cap(@q1, 8)
    set_level(@q1, "4")
    level_id = TeamPlanningOverride.find_by!(facet: "level").event_id

    agreed = split(@q1, level_id)

    assert_equal [ [ agreed, "level", level_id ] ], TeamPlanningOverride.where(scenario_id: agreed).pluck(:scenario_id, :facet, :event_id)
    assert_equal [ CAP ], TeamPlanningOverride.where(scenario_id: @q1).pluck(:facet)
  end

  def place(scenario_id)
    @handler.set_change(@plan_id, TeamPlanning::Events::AssignmentSet, scenario_id:, subject_id: @person.id,
                                                                       end_state: { placements: [ { unit_id: @plan_id, allocation: 1.0 } ] })
  end

  def move_later(scenario_id) = @handler.move_change(@plan_id, scenario_id:, subject_id: @person.id, facet: "assignment", direction: "later")

  should "move a moved change's row to the step it reached, back on undo and across again on redo" do
    q2 = fork(@q1, "then", "Q2", ends_on: "2027-06-30")
    set_cap(@q1, 8)
    place(@q1)
    placed = TeamPlanningOverride.find_by!(facet: "assignment").event_id
    rows = -> { TeamPlanningOverride.where(facet: "assignment").pluck(:scenario_id, :event_id) }

    move_later(@q1)
    assert_equal [ [ q2, placed ] ], rows.call
    assert_equal [ CAP ], TeamPlanningOverride.where(scenario_id: @q1).pluck(:facet)

    @handler.undo_change(@plan_id, scenario_id: q2)
    assert_equal [ [ @q1, placed ] ], rows.call

    @handler.redo_change(@plan_id, scenario_id: q2)
    assert_equal [ [ q2, placed ] ], rows.call
  end

  context "rebuild contract" do
    should "reset! + replay produce identical read-model state, including the stable ids" do
      q2 = fork(@q1, "then", "Q2", ends_on: "2027-06-30")
      place(@q1)
      move_later(@q1)
      @handler.undo_change(@plan_id, scenario_id: q2)
      @handler.redo_change(@plan_id, scenario_id: q2)
      set_cap(@q1, 8)
      @handler.pin_change(@plan_id, scenario_id: @lean, subject_id: @plan_id, facet: CAP)
      set_cap(@q1, 6, note: "Hiring freeze until the spring")
      gone = fork(@q1, "instead", "Gone")
      set_cap(gone, 2)
      @handler.clear_change(@plan_id, scenario_id: gone, subject_id: @plan_id, facet: CAP)
      pin_id = TeamPlanningOverride.find_by!(scenario_id: @lean).event_id
      @handler.note_change(@plan_id, scenario_id: @lean, event_id: pin_id, note: "Lean keeps the old cap")
      set_cap(@lean, 4)
      @handler.undo_change(@plan_id, scenario_id: @lean)
      assert_equal "Lean keeps the old cap", TeamPlanningOverride.find_by!(scenario_id: @lean).note.reveal
      @handler.set_change(@plan_id, TeamPlanning::Events::LevelSet, scenario_id: @q1, subject_id: @person.id,
                                                                    end_state: { level: "4" }, note: "Ready since the launch")
      level_id = TeamPlanningOverride.find_by!(scenario_id: @q1, facet: "level").event_id
      @handler.note_change(@plan_id, scenario_id: @q1, event_id: level_id, note: "Ready, and asked for it")
      split(@q1, level_id)

      before = snapshot_read_models(TeamPlanning::Projections::Overrides, @tenant)
      assert_equal 4, before[:overrides].size

      TeamPlanning::Projections::Overrides.reset!(tenant: @tenant)
      assert_equal 0, TeamPlanningOverride.count
      Projections::Replayer.replay(projection_class: TeamPlanning::Projections::Overrides, tenant: @tenant)

      assert_equal before, snapshot_read_models(TeamPlanning::Projections::Overrides, @tenant)
    end
  end

  should "keep one tenant's overrides out of another's" do
    set_cap(@q1, 8)
    other = create(:tenant)
    ActsAsTenant.with_tenant(other) { assert_empty TeamPlanningOverride.all }
  end
end
