# frozen_string_literal: true

require "test_helper"

class TeamPlanning::CommandHandlerOverridesTest < ActiveSupport::TestCase
  SYSTEM = OrgGraph::Authorization::SYSTEM

  class HeadcountCap < TeamPlanning::RuleKind
    def self.rule_name = "test_headcount_cap"
    def self.description = "The most people a unit may hold"
    def self.default = { "cap" => 10 }
  end

  class Strictness < TeamPlanning::RuleKind
    def self.rule_name = "test_strictness"
    def self.description = "Whether going over budget is refused or only flagged"
    def self.default = { "level" => "flag" }
  end

  CAP = "rule:test_headcount_cap"

  setup do
    [ HeadcountCap, Strictness ].each { TeamPlanning::RuleKinds.register(it) }
    @tenant = create(:tenant)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    departments = SecureRandom.uuid_v7
    @engineering = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: "2026-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: departments, effective_on: "2026-01-01")

      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant, name: "Ada Editor"))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: Date.new(2026, 3, 2))
      @q1 = fork(@plan_id, "then", "Q1", ends_on: "2026-06-30")
      @lean = fork(@q1, "instead", "Lean Q1")
    end
  end

  teardown { [ HeadcountCap, Strictness ].each { TeamPlanning::RuleKinds.unregister(it) } }

  def as_tenant(tenant = @tenant, &) = ActsAsTenant.with_tenant(tenant, &)

  def context_for(tenant_user) = AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)

  def handler(as = @editor) = TeamPlanning::CommandHandler.new(actor: context_for(as))

  def fork(parent_id, relation, name, ends_on: nil)
    SecureRandom.uuid_v7.tap { handler.fork_scenario(@plan_id, it, parent_id:, relation:, name:, ends_on:) }
  end

  def set_cap(scenario_id, cap, subject_id: @plan_id, rule: "test_headcount_cap")
    as_tenant { handler.set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id:, subject_id:, end_state: { rule:, value: { cap: } }) }
  end

  def clear(scenario_id, facet: CAP, subject_id: @plan_id, as: @editor)
    as_tenant { handler(as).clear_change(@plan_id, scenario_id:, subject_id:, facet:) }
  end

  def pin(scenario_id, facet: CAP, subject_id: @plan_id, as: @editor)
    as_tenant { handler(as).pin_change(@plan_id, scenario_id:, subject_id:, facet:) }
  end

  def cap(scenario_id, unit_id: nil)
    as_tenant do
      TeamPlanning::Resolution.new(context: context_for(@editor), plan: TeamPlanningPlan.find(@plan_id), scenario_id:)
        .structure.rule("test_headcount_cap", unit_id:)["cap"]
    end
  end

  def override(scenario_id, facet: CAP) = as_tenant { TeamPlanningOverride.find_by(scenario_id:, facet:) }

  def refusal(&) = assert_raises(TeamPlanning::Error, &).message

  should "hand a rule back to the parent on a clear, and drop the override" do
    set_cap(@q1, 8)
    set_cap(@lean, 5)
    assert_equal [ 8, 5 ], [ cap(@q1), cap(@lean) ]

    clear(@lean)

    assert_equal 8, cap(@lean)
    assert_nil override(@lean)
    stream = as_tenant { Rails.configuration.event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).to_a }
    assert_equal 1, stream.count { it.is_a?(TeamPlanning::Events::RuleSet) && it.data[:scenario_id] == @lean }
  end

  should "clear one rule and leave another on the same subject" do
    set_cap(@lean, 5)
    as_tenant do
      handler.set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id: @lean, subject_id: @plan_id,
                                                                    end_state: { rule: "test_strictness", value: { level: "refuse" } })
    end

    clear(@lean)

    assert_equal 10, cap(@lean)
    assert_equal({ "level" => "refuse" }, override(@lean, facet: "rule:test_strictness").end_state["value"])
  end

  should "pin a parent's change, keep it after the parent moves on, and say where it came from" do
    set_cap(@q1, 8)
    set_by = override(@q1).event_id
    pin(@lean)
    set_cap(@q1, 3)

    assert_equal [ 3, 8 ], [ cap(@q1), cap(@lean) ]
    row = override(@lean)
    assert_equal [ true, @q1, set_by, @editor.person_id ], row.values_at(:pinned, :pinned_from_scenario_id, :pinned_from_event_id, :set_by_id)
    assert_equal({ "rule" => "test_headcount_cap", "value" => { "cap" => 8 } }, row.end_state)
  end

  should "pin a value from the baseline, read off the parent's map, so a later change in the parent doesn't reach it" do
    as_tenant { PlanningRuleDefault.create!(rule: "test_headcount_cap", value: { cap: 7 }) }
    pin(@lean, subject_id: @engineering)
    set_cap(@q1, 3, subject_id: @engineering)

    assert_equal [ 3, 7 ], [ cap(@q1, unit_id: @engineering), cap(@lean, unit_id: @engineering) ]
    assert_equal [ true, nil, nil ], override(@lean).values_at(:pinned, :pinned_from_scenario_id, :pinned_from_event_id)
  end

  should "pin a unit's rule to what it inherits from the plan-wide rule above it" do
    set_cap(@q1, 6)
    pin(@lean, subject_id: @engineering)
    set_cap(@q1, 2)

    assert_equal [ 2, 6 ], [ cap(@q1, unit_id: @engineering), cap(@lean, unit_id: @engineering) ]
  end

  should "read clears and pins back from the stored stream" do
    set_cap(@q1, 8)
    set_cap(@lean, 5)
    clear(@lean)
    pin(@lean)

    plan = as_tenant { TeamPlanning::Repository.new.load_plan(@plan_id) }
    pinned = plan.changes_in(@lean).sole
    assert_equal [ TeamPlanning::Events::RuleSet, [ @plan_id, CAP ], { "cap" => 8 } ], [ pinned.class, pinned.key, pinned.data[:value] ]
  end

  should "refuse to clear what the scenario doesn't change, to pin the baseline or what it already changes, and a facet no kind holds" do
    set_cap(@lean, 5)

    assert_equal "Q1 doesn't change this, so there is nothing to clear", refusal { clear(@q1) }
    assert_equal "The baseline inherits nothing to pin", refusal { pin(@plan_id) }
    assert_equal "Lean Q1 already changes this: clear it to follow its parent, or set it", refusal { pin(@lean) }
    assert_equal "No kind of change holds level", refusal { pin(@q1, facet: "level") }
    assert_equal "The baseline doesn't hold this", refusal { pin(@q1, subject_id: SecureRandom.uuid_v7) }
  end

  should "refuse someone who can't edit the plan, as an unknown plan" do
    viewer = as_tenant { create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant)) }
    as_tenant { handler.add_member(@plan_id, viewer.person_id, role: "viewer") }
    set_cap(@lean, 5)

    assert_equal "No such plan", refusal { clear(@lean, as: viewer) }
    assert_equal "No such plan", refusal { pin(@q1, as: viewer) }
    assert_equal 5, cap(@lean)
  end
end
