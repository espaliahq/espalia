# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::CloseStepTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @holder = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
    end
    @plan_id = call(:CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    call(:AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @q1 = call(:ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]
    @q2 = call(:ForkScenario, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2", ends_on: "2026-09-30")[:scenario_id]
    travel_to Time.utc(2026, 7, 1, 9)
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def call(operation, as: @holder, **params)
    context = AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person)
    as_tenant { "Operations::TeamPlanning::#{operation}".constantize.call(context:, params:) }
  end

  def close(scenario_id = @q1, as: @holder) = call(:CloseStep, as:, plan_id: @plan_id, scenario_id:)

  def reopen(scenario_id = @q1, as: @holder) = call(:ReopenStep, as:, plan_id: @plan_id, scenario_id:)

  def refusal(&) = assert_raises(Operations::Base::ParameterError, &).message

  def closed = as_tenant { TeamPlanning::Repository.new.load_plan(@plan_id).closed_steps.map(&:first) }

  should "close a step once its period has ended, and reopen it" do
    assert_equal({ plan_id: @plan_id, scenario_id: @q1, ends_on: "2026-06-30" }, close)
    assert_equal [ @q1 ], closed

    assert_equal({ plan_id: @plan_id, scenario_id: @q1 }, reopen)
    assert_empty closed
  end

  should "name why a step can't close" do
    travel_to Time.utc(2026, 10, 1, 9) do
      assert_equal "Close the step before this one first", refusal { close(@q2) }
    end
    travel_to Time.utc(2026, 6, 30, 9)
    assert_equal "This step ends on 2026-06-30: it can be closed from the day after", refusal { close }
    assert_empty closed
  end

  should "reopen only the last step closed" do
    assert_equal "This step isn't closed", refusal { reopen }
    close
    travel_to Time.utc(2026, 10, 1, 9)
    close(@q2)

    assert_equal "Only the last step closed can be reopened: reopen the steps after it first", refusal { reopen }
  end

  should "read as missing to a viewer either way" do
    assert_equal "No such plan", refusal { close(as: @viewer) }
    close
    assert_equal "No such plan", refusal { reopen(as: @viewer) }
    assert_equal [ @q1 ], closed
  end

  should "refuse a scenario id that isn't a UUID" do
    assert_match "scenario_id must be a UUID", refusal { close("q1") }
  end
end
