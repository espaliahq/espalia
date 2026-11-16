# frozen_string_literal: true

require "test_helper"

# The plan page asks for every Remove dialog's notice in one load of the plan
# ([#439](https://github.com/espaliahq/espalia/issues/439)). Each must read as
# the notice the MCP approval shows for that scenario alone.
class Operations::TeamPlanning::RemoveScenarioNoticesTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @holder = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      people = create_list(:person, 2, tenant: @tenant)
      people.each do |person|
        OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                .record_person(person.id, provider: "espalia", effective_on: (Date.current - 30).iso8601, employment_status: "employed", level: "3")
      end
      @plan_id = call(Operations::TeamPlanning::CreatePlan, @holder, name: "Next year", base_on: (Date.current + 1).iso8601)[:plan_id]
      call(Operations::TeamPlanning::AddPlanMember, @holder, plan_id: @plan_id, person_id: @editor.person_id, role: "editor")
      @one = fork("One pay change", relation: "then")
      @two = fork("Two pay changes", parent_id: @one, relation: "instead")
      @none = fork("No pay changes", parent_id: @one, relation: "instead")
      set_pay(@one, people.first)
      people.each { set_pay(@two, it) }
      @scenario_ids = [ @plan_id, @one, @two, @none ]
    end
  end

  should "give each scenario the notice it gets alone" do
    ActsAsTenant.with_tenant(@tenant) do
      batch = notices(@editor)

      @scenario_ids.each do |scenario_id|
        single = Operations::TeamPlanning::RemoveScenario.approval_notice(context: context(@editor), params: { plan_id: @plan_id, scenario_id: })
        if single
          assert_equal single, batch[scenario_id]
        else
          assert_not batch.key?(scenario_id)
        end
      end
      assert_equal "This scenario holds 1 change to pay you can't see. Removing it removes that too.", batch[@one]
      assert_equal "This scenario holds 2 changes to pay you can't see. Removing it removes those too.", batch[@two]
      assert_not batch.key?(@none)
    end
  end

  should "give someone who sees pay no notices" do
    ActsAsTenant.with_tenant(@tenant) { assert_equal({}, notices(@holder)) }
  end

  should "load the plan once for every scenario" do
    ActsAsTenant.with_tenant(@tenant) do
      repository = TeamPlanning::Repository.new
      loads = 0
      counting = Object.new
      counting.define_singleton_method(:load_plan) { |plan_id| loads += 1; repository.load_plan(plan_id) }
      TeamPlanning::Repository.stub(:new, counting) { notices(@editor) }
      assert_equal 1, loads
    end
  end

  private

  def notices(account)
    Operations::TeamPlanning::RemoveScenario.approval_notices(context: context(account), plan_id: @plan_id, scenario_ids: @scenario_ids)
  end

  def fork(name, **where)
    call(Operations::TeamPlanning::ForkScenario, @holder, plan_id: @plan_id, name:, **where)[:scenario_id]
  end

  def set_pay(scenario_id, person)
    call(Operations::TeamPlanning::SetActualPay, @holder, plan_id: @plan_id, scenario_id:, person_id: person.id,
                                                          amount: "92417", currency: "AUD", period: "year", basis: "full_time")
  end

  def context(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def call(operation, account, **params) = operation.call(context: context(account), params:)
end
