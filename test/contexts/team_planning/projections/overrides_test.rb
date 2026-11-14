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

  def set_cap(scenario_id, cap)
    @handler.set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id:, subject_id: @plan_id,
                                                                 end_state: { rule: "test_headcount_cap", value: { cap: } })
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

  should "drop a removed scenario's rows, and every row of a deleted plan" do
    set_cap(@q1, 8)
    set_cap(@lean, 5)

    @handler.remove_scenario(@plan_id, @lean)
    assert_equal [ @q1 ], overrides.map(&:first)

    @handler.delete_plan(@plan_id)
    assert_empty overrides
  end

  context "rebuild contract" do
    should "reset! + replay produce identical read-model state, including the stable ids" do
      set_cap(@q1, 8)
      @handler.pin_change(@plan_id, scenario_id: @lean, subject_id: @plan_id, facet: CAP)
      set_cap(@q1, 6)
      gone = fork(@q1, "instead", "Gone")
      set_cap(gone, 2)
      @handler.clear_change(@plan_id, scenario_id: gone, subject_id: @plan_id, facet: CAP)

      before = snapshot_read_models(TeamPlanning::Projections::Overrides, @tenant)
      assert_equal 2, before[:overrides].size

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
