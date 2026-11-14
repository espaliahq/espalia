# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::OverridesTest < ActiveSupport::TestCase
  SYSTEM = OrgGraph::Authorization::SYSTEM
  CAP = "rule:test_headcount_cap"

  class HeadcountCap < TeamPlanning::RuleKind
    def self.rule_name = "test_headcount_cap"
    def self.description = "The most people a unit may hold"
    def self.default = { "cap" => 10 }
  end

  setup do
    TeamPlanning::RuleKinds.register(HeadcountCap)
    @tenant = create(:tenant)
    departments = SecureRandom.uuid_v7
    @engineering = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
      structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: "2026-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: departments, effective_on: "2026-01-01")

      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant, name: "Ada Editor"))
      @viewer = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: Date.new(2026, 3, 2))
      handler.add_member(@plan_id, @viewer.person_id, role: "viewer")
      @q1 = fork(@plan_id, "then", "Q1", ends_on: "2026-06-30")
      @lean = fork(@q1, "instead", "Lean Q1")
    end
  end

  teardown { TeamPlanning::RuleKinds.unregister(HeadcountCap) }

  def as_tenant(tenant = @tenant, &) = ActsAsTenant.with_tenant(tenant, &)

  def context_for(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def handler = TeamPlanning::CommandHandler.new(actor: context_for(@editor))

  def fork(parent_id, relation, name, ends_on: nil)
    SecureRandom.uuid_v7.tap { handler.fork_scenario(@plan_id, it, parent_id:, relation:, name:, ends_on:) }
  end

  def set_cap(scenario_id, cap, subject_id: @plan_id)
    as_tenant do
      handler.set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id:, subject_id:,
                                                                   end_state: { rule: "test_headcount_cap", value: { cap: } })
    end
  end

  def call(operation, as: @editor, **params)
    as_tenant { "Operations::TeamPlanning::#{operation}".constantize.call(context: context_for(as), params:) }
  end

  def overrides(scenario_id, as: @editor) = call(:Overrides, as:, plan_id: @plan_id, scenario_id:)[:overrides]

  def change(operation, scenario_id, as: @editor, subject_id: @plan_id, facet: CAP)
    call(operation, as:, plan_id: @plan_id, scenario_id:, subject_id:, facet:)
  end

  should "list a scenario's own change beside what its parent gives it" do
    set_cap(@q1, 8)
    set_cap(@lean, 5)

    assert_equal [ { subject_id: @plan_id, facet: CAP, kind: "rule_set", end_state: { "rule" => "test_headcount_cap", "value" => { "cap" => 5 } },
                     pinned: false, pinned_from: nil, parent_moved: nil,
                     inherits: { scenario_id: @q1, end_state: { "rule" => "test_headcount_cap", "value" => { "cap" => 8 } } },
                     set_by: { person_id: @editor.person_id, name: "Ada Editor" }, set_at: "2026-02-01T09:00:00Z" } ],
                 overrides(@lean)
  end

  should "read what the baseline gives when no ancestor changes it" do
    set_cap(@lean, 5)

    assert_equal({ scenario_id: nil, end_state: { "rule" => "test_headcount_cap", "value" => { "cap" => 10 } } },
                 overrides(@lean).sole[:inherits])
  end

  should "clear a change, handing it back to the parent" do
    set_cap(@lean, 5)

    assert_equal({ plan_id: @plan_id, scenario_id: @lean, subject_id: @plan_id, facet: CAP, cleared: true }, change(:ClearChange, @lean))
    assert_empty overrides(@lean)
  end

  should "pin what the parent gives, and say when the parent moves on" do
    set_cap(@q1, 8)
    pinned = change(:PinChange, @lean)

    assert_equal [ true, { "rule" => "test_headcount_cap", "value" => { "cap" => 8 } }, false ],
                 pinned.values_at(:pinned, :end_state, :parent_moved)
    assert_equal @q1, pinned[:pinned_from][:scenario_id]
    assert_equal [ @plan_id, @lean ], pinned.values_at(:plan_id, :scenario_id)

    set_cap(@q1, 6)
    listed = overrides(@lean).sole
    assert_equal [ true, { "cap" => 6 } ], [ listed[:parent_moved], listed.dig(:inherits, :end_state, "value") ]
    assert_equal({ "cap" => 8 }, listed.dig(:end_state, "value"))
  end

  should "pin the baseline's value with no scenario to name" do
    pinned = change(:PinChange, @q1)

    assert_equal [ { scenario_id: nil, event_id: nil }, false ], pinned.values_at(:pinned_from, :parent_moved)
    assert_equal({ "cap" => 10 }, pinned.dig(:end_state, "value"))
  end

  should "name a forgotten setter as a former member" do
    set_cap(@lean, 5)
    as_tenant { @editor.person.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current) }

    assert_equal Person::FORMER_MEMBER, overrides(@lean, as: @viewer).sole.dig(:set_by, :name)
  end

  should "refuse a clear with nothing to clear, a pin of the baseline, and a scenario not in the plan" do
    error = assert_raises(Operations::Base::ParameterError) { change(:ClearChange, @lean) }
    assert_match "nothing to clear", error.message

    error = assert_raises(Operations::Base::ParameterError) { change(:PinChange, @plan_id) }
    assert_equal "The baseline inherits nothing to pin", error.message

    error = assert_raises(Operations::Base::ParameterError) { overrides(SecureRandom.uuid_v7) }
    assert_equal "This plan has no such scenario", error.message
  end

  should "let a viewer read, and refuse it a write as an unknown plan" do
    set_cap(@lean, 5)

    assert_equal 1, overrides(@lean, as: @viewer).size
    %i[ClearChange PinChange].each do |operation|
      error = assert_raises(Operations::Base::ParameterError) { change(operation, @q1, as: @viewer) }
      assert_equal "No such plan", error.message
    end
  end

  should "read as an unknown plan to someone not in it, and in another tenant" do
    error = assert_raises(Operations::Base::ParameterError) { overrides(@lean, as: @outsider) }
    assert_equal "No such plan", error.message

    other = create(:tenant)
    stranger = ActsAsTenant.with_tenant(other) { create(:tenant_user, tenant: other, role: :admin, person: create(:person, tenant: other)) }
    error = assert_raises(Operations::Base::ParameterError) do
      ActsAsTenant.with_tenant(other) do
        Operations::TeamPlanning::Overrides.call(context: context_for(stranger), params: { plan_id: @plan_id, scenario_id: @lean })
      end
    end
    assert_equal "No such plan", error.message
  end
end
