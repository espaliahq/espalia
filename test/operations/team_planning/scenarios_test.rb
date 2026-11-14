# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::ScenariosTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @other_admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2027-01-01")[:plan_id]
  end

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person)
      operation.call(context: context, params: params)
    end
  end

  def fork(**params) = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, **params)

  def refusal(operation, as: @admin, **params)
    assert_raises(Operations::Base::ParameterError) { call(operation, as:, plan_id: @plan_id, **params) }.message
  end

  context "ForkScenario" do
    should "fork a step after the baseline by default, and an alternative to it" do
      q1 = fork(relation: "then", name: "Q1", ends_on: "2027-03-31")
      assert_equal({ plan_id: @plan_id, scenario_id: q1[:scenario_id], parent_id: @plan_id, relation: "then", name: "Q1",
                     starts_on: "2027-01-01", ends_on: "2027-03-31" }, q1)

      lean = fork(parent_id: q1[:scenario_id].upcase, relation: "instead", name: "Lean Q1")
      assert_equal [ q1[:scenario_id], "2027-01-01", "2027-03-31" ], lean.values_at(:parent_id, :starts_on, :ends_on)
    end

    should "pass on the plan's refusals and refuse bad ids and dates" do
      assert_equal "Say when this step ends", refusal(Operations::TeamPlanning::ForkScenario, relation: "then", name: "Q1")
      assert_equal "parent_id must be a UUID, got \"q1\"",
                   refusal(Operations::TeamPlanning::ForkScenario, parent_id: "q1", relation: "instead", name: "Q1")
      assert_equal "ends_on must be a date, YYYY-MM-DD",
                   refusal(Operations::TeamPlanning::ForkScenario, relation: "then", name: "Q1", ends_on: "March")
    end
  end

  context "with a step and its alternative" do
    setup do
      @q1 = fork(relation: "then", name: "Q1", ends_on: "2027-03-31")[:scenario_id]
      @lean = fork(parent_id: @q1, relation: "instead", name: "Lean Q1")[:scenario_id]
    end

    should "list the baseline first, then each scenario with its parent, relation and period" do
      call(Operations::TeamPlanning::SetScenarioPeriod, plan_id: @plan_id, scenario_id: @q1, ends_on: "2027-02-28")

      assert_equal({ plan_id: @plan_id, scenarios: [
        { scenario_id: @plan_id, parent_id: nil, relation: nil, name: "Baseline", starts_on: "2027-01-01", ends_on: nil },
        { scenario_id: @q1, parent_id: @plan_id, relation: "then", name: "Q1", starts_on: "2027-01-01", ends_on: "2027-02-28" },
        { scenario_id: @lean, parent_id: @q1, relation: "instead", name: "Lean Q1", starts_on: "2027-01-01", ends_on: "2027-02-28" }
      ] }, call(Operations::TeamPlanning::Scenarios, plan_id: @plan_id))
    end

    should "move a step's end and say the period it now has" do
      assert_equal({ plan_id: @plan_id, scenario_id: @q1, starts_on: "2027-01-01", ends_on: "2027-04-30" },
                   call(Operations::TeamPlanning::SetScenarioPeriod, plan_id: @plan_id, scenario_id: @q1, ends_on: "2027-04-30"))
      assert_equal "Lean Q1 is an alternative: it takes its period from Q1",
                   refusal(Operations::TeamPlanning::SetScenarioPeriod, scenario_id: @lean, ends_on: "2027-04-30")
    end

    should "remove a leaf, and refuse a scenario others fork from" do
      assert_equal "1 scenario forks from Q1: remove it first",
                   refusal(Operations::TeamPlanning::RemoveScenario, scenario_id: @q1)
      assert_equal({ plan_id: @plan_id, scenario_id: @lean, removed: true },
                   call(Operations::TeamPlanning::RemoveScenario, plan_id: @plan_id, scenario_id: @lean))
      assert_equal [ @plan_id, @q1 ], call(Operations::TeamPlanning::Scenarios, plan_id: @plan_id)[:scenarios].pluck(:scenario_id)
    end

    should "read as missing to an admin outside the plan" do
      [ [ Operations::TeamPlanning::Scenarios, {} ],
        [ Operations::TeamPlanning::ForkScenario, { parent_id: @q1, relation: "instead", name: "Mine" } ],
        [ Operations::TeamPlanning::SetScenarioPeriod, { scenario_id: @q1, ends_on: "2027-04-30" } ],
        [ Operations::TeamPlanning::RemoveScenario, { scenario_id: @lean } ] ].each do |operation, params|
        assert_equal "No such plan", refusal(operation, as: @other_admin, **params), operation.name
      end
    end
  end
end
