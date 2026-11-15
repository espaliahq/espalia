# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::SettleConflictTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  BASE_ON = Date.new(2026, 3, 2)

  setup do
    @tenant = create(:tenant)
    @org = OrgGraph::CommandHandler.new(actor: SYSTEM)

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @brook = create(:person, tenant: @tenant, name: "Brook Tamsin")
      @org.record_person(@brook.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", level: "3")

      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: BASE_ON)
      handler.add_member(@plan_id, @viewer.person_id, role: "viewer")
      @q1 = fork("Q1", parent_id: @plan_id, relation: "then", ends_on: "2026-06-30")
      @lean = fork("Lean Q1", parent_id: @q1, relation: "instead")
      @bold = fork("Bold Q1", parent_id: @q1, relation: "instead")
    end

    call(:SetPlannedLevel, plan_id: @plan_id, scenario_id: @q1, person_id: @brook.id, level: "4", note: "Promised in March")
    travel_to(Time.utc(2026, 3, 20, 9)) { as_tenant { @org.change_level(@brook.id, "5", **ESPALIA, effective_on: "2026-03-20") } }
    travel_to Time.utc(2026, 3, 25, 9)
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def context_for(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def handler = TeamPlanning::CommandHandler.new(actor: context_for(@editor))

  def fork(name, parent_id:, relation:, **period)
    SecureRandom.uuid_v7.tap { handler.fork_scenario(@plan_id, it, parent_id:, relation:, name:, **period) }
  end

  def call(operation, as: @editor, **params)
    as_tenant { "Operations::TeamPlanning::#{operation}".constantize.call(context: context_for(as), params:) }
  end

  def rebase = call(:RebasePlan, plan_id: @plan_id, base_on: BASE_ON.iso8601)

  def settle(scenario_id, choice, as: @editor, **params)
    call(:SettleConflict, as:, plan_id: @plan_id, scenario_id:, subject_id: @brook.id, facet: "level", choice:, **params)
  end

  def brook(scenario_id) = call(:Status, plan_id: @plan_id, scenario_id:)[:statuses].find { it[:subject_id] == @brook.id }

  def last_entry(scenario_id) = call(:History, plan_id: @plan_id, scenario_id:)[:entries].last

  def map(scenario_id) = call(:ScenarioMap, plan_id: @plan_id, scenario_id:).to_json

  def refusal(&) = assert_raises(Operations::Base::ParameterError, &).message

  should "keep the plan in the scenario that made the change, which status reads as settled and history as kept" do
    rebase
    assert_equal "conflicting", brook(@q1)[:status].to_s

    assert_equal({ plan_id: @plan_id, scenario_id: @q1, subject_id: @brook.id, facet: "level", choice: "plan" }, settle(@q1, "plan"))
    status = brook(@q1)
    assert_equal [ "pending", nil ], [ status[:status].to_s, status[:since] ]
    assert_equal({ value: "Promised in March" }, status[:note])

    entry = last_entry(@q1)
    assert_equal [ "set", { "since" => "2026-03-25", "choice" => "plan" } ], entry.values_at(:action, :settles)
    assert_equal [ "level" ], entry[:sealed_fields]
  end

  should "keep the plan where the scenario inherits a sealed level, by setting it there, the parent left alone" do
    rebase
    parent = map(@q1)
    settle(@lean, "plan", note: "Still promised")

    assert_equal "pending", brook(@lean)[:status].to_s
    assert_equal({ value: "Still promised" }, brook(@lean)[:note])
    assert_equal [ "set", { "since" => "2026-03-25", "choice" => "plan" } ], last_entry(@lean).values_at(:action, :settles)
    assert_equal parent, map(@q1)
    assert_equal "conflicting", brook(@q1)[:status].to_s
  end

  should "follow reality in one child alone, the parent and a sibling byte-identical before and after" do
    rebase
    parent, sibling = map(@q1), map(@bold)
    settle(@lean, "reality")

    assert_not_equal "conflicting", brook(@lean)[:status].to_s
    assert_equal [ "set", { "since" => "2026-03-25", "choice" => "reality" } ], last_entry(@lean).values_at(:action, :settles)
    assert_equal parent, map(@q1)
    assert_equal sibling, map(@bold)
    assert_equal "conflicting", brook(@bold)[:status].to_s
  end

  should "leave an ordinary edit unmarked" do
    call(:SetPlannedLevel, plan_id: @plan_id, scenario_id: @q1, person_id: @brook.id, level: "6")

    assert_nil last_entry(@q1)[:settles]
  end

  should "refuse a conflict no update carried forward, and a viewer" do
    assert_equal "conflicting", brook(@q1)[:status].to_s
    assert_match(/nothing to settle: update the plan to today first/, refusal { settle(@q1, "plan") })

    rebase
    assert_equal "No such plan", refusal { settle(@q1, "plan", as: @viewer) }
    assert_equal "conflicting", brook(@q1)[:status].to_s
  end
end
