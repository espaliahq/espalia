# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::RemovedScenariosTest < ActiveSupport::TestCase
  CAP = "rule:test_headcount_cap"

  class HeadcountCap < TeamPlanning::RuleKind
    def self.rule_name = "test_headcount_cap"
    def self.description = "The most people a unit may hold"
    def self.default = { "cap" => 10 }
  end

  setup do
    TeamPlanning::RuleKinds.register(HeadcountCap)
    @tenant = create(:tenant)
    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant, name: "Ada Editor"))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: Date.new(2026, 3, 2))
      handler.add_member(@plan_id, @viewer.person_id, role: "viewer")
      @q1 = fork(@plan_id, "then", "Q1", ends_on: "2026-06-30")
      @lean = fork(@q1, "instead", "Lean Q1")
      @q2 = fork(@q1, "then", "Q2")
    end
  end

  teardown { TeamPlanning::RuleKinds.unregister(HeadcountCap) }

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def context_for(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def handler = TeamPlanning::CommandHandler.new(actor: context_for(@editor))

  def fork(parent_id, relation, name, ends_on: nil)
    SecureRandom.uuid_v7.tap { handler.fork_scenario(@plan_id, it, parent_id:, relation:, name:, ends_on:) }
  end

  def set_cap(scenario_id, cap)
    as_tenant do
      handler.set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id:, subject_id: @plan_id,
                                                                   end_state: { rule: "test_headcount_cap", value: { cap: } })
    end
  end

  def remove(scenario_id) = as_tenant { handler.remove_scenario(@plan_id, scenario_id) }

  def call(as: @editor, **params)
    as_tenant { Operations::TeamPlanning::RemovedScenarios.call(context: context_for(as), params: { plan_id: @plan_id, **params }) }
  end

  should "list each removed scenario newest first, with its name, period, count, and who removed it when" do
    set_cap(@lean, 8)
    set_cap(@lean, 6)
    remove(@lean)
    travel 1.day
    remove(@q2)

    result = call(as: @viewer)
    assert_equal [ @plan_id, 1, false ], result.values_at(:plan_id, :page, :next_page)
    assert_equal [
      { scenario_id: @q2, name: "Q2", relation: "then", starts_on: "2026-07-01", ends_on: nil, changes: 0,
        removed_by: { person_id: @editor.person_id, name: "Ada Editor" }, removed_at: "2026-02-02T09:00:00Z" },
      { scenario_id: @lean, name: "Lean Q1", relation: "instead", starts_on: "2026-03-02", ends_on: "2026-06-30", changes: 1,
        removed_by: { person_id: @editor.person_id, name: "Ada Editor" }, removed_at: "2026-02-01T09:00:00Z" }
    ], result[:removed]
  end

  should "list nothing for a plan with no removed scenario, and refuse anyone outside the plan as an unknown plan" do
    assert_empty call[:removed]

    error = assert_raises(Operations::Base::ParameterError) { call(as: @outsider) }
    assert_equal "No such plan", error.message
  end

  should "still list them once the plan is archived" do
    remove(@lean)
    as_tenant { handler.archive_plan(@plan_id) }

    assert_equal [ @lean ], call(as: @viewer)[:removed].pluck(:scenario_id)
  end

  should "page the list, saying when another page follows" do
    remove(@lean)
    remove(@q2)
    Operations::TeamPlanning::RemovedScenarios.stub(:per_page, 1) do
      assert_equal [ [ @q2 ], true ], call.then { [ it[:removed].pluck(:scenario_id), it[:next_page] ] }
      assert_equal [ [ @lean ], false ], call(page: 2).then { [ it[:removed].pluck(:scenario_id), it[:next_page] ] }
    end
  end

  should "read the name as removed once the plan's key is gone" do
    remove(@lean)
    as_tenant { PlanKeyStore.new.destroy_plan(@plan_id) }

    assert_nil as_tenant { TeamPlanningRemovedScenario.find(@lean).name.reveal }
  end

  context "rebuild" do
    setup do
      set_cap(@lean, 8)
      as_tenant { handler.set_change(@plan_id, TeamPlanning::Events::LevelSet, scenario_id: @lean, subject_id: @editor.person_id, end_state: { level: "4" }) }
      remove(@lean)
      @before = call[:removed]
      assert_equal [ 2 ], @before.pluck(:changes)
    end

    should "read the same after History alone is rebuilt" do
      TeamPlanning::Projections::History.reset!(tenant: @tenant)
      Projections::Replayer.replay(projection_class: TeamPlanning::Projections::History, tenant: @tenant)

      assert_equal @before, call[:removed]
    end

    should "read the same after Scenarios alone is rebuilt" do
      TeamPlanning::Projections::Scenarios.reset!(tenant: @tenant)
      Projections::Replayer.replay(projection_class: TeamPlanning::Projections::Scenarios, tenant: @tenant)

      assert_equal @before, call[:removed]
    end
  end
end
