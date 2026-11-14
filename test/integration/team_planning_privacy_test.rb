# frozen_string_literal: true

require "test_helper"

# A plan holds pay and notes, so only its members may reach it. This walks
# every Team Planning tool as each kind of outsider and asserts each gets
# nothing: a plan they aren't in reads as an unknown id, a list leaves it
# out, and nothing is written. A new tool joins the walk on its own.
class TeamPlanningPrivacyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @editor = account(role: :member, team_planner: true)
    @viewer = account(role: :member)
    @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Pay review 2027")[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person.id, role: "viewer")
  end

  teardown { ActsAsTenant.current_tenant = nil }

  OPERATIONS = -> { Operations::Registry.all.select { it.name.start_with?("Operations::TeamPlanning::") } }

  should "walk at least the plan tools 1.2 ships" do
    names = OPERATIONS.call.map { Operations::Registry.tool_name_for(it) }
    assert_includes names, "team_planning_plan_members"
    assert_includes names, "team_planning_delete_frozen_plan"
  end

  should "give a tenant admin, an Org Graph editor, a planner, a global admin and a plain member nothing from a plan they aren't in" do
    outsiders.each do |who, context|
      OPERATIONS.call.each do |operation|
        tool = Operations::Registry.tool_name_for(operation)
        before = stream_size

        if operation.parameters.key?(:plan_id)
          error = assert_raises(Operations::Base::ParameterError, "#{tool} as #{who}") { operation.call(context:, params: params_for(operation)) }
          assert_equal "No such plan", error.message, "#{tool} as #{who}"
        else
          begin
            output = operation.call(context:, params: params_for(operation)).to_json
            assert_not_includes output, @plan_id, "#{tool} as #{who} names the plan"
            assert_not_includes output, "Pay review", "#{tool} as #{who} shows the plan's name"
          rescue Pundit::NotAuthorizedError
            nil
          end
        end
        assert_equal before, stream_size, "#{tool} as #{who} wrote to the plan"
      end
    end
  end

  should "read as an unknown id to a viewer for every change but leaving" do
    context = context_for(@viewer)
    OPERATIONS.call.select { it.parameters.key?(:plan_id) && it.category != :read }.each do |operation|
      next if operation == Operations::TeamPlanning::RemovePlanMember

      error = assert_raises(Operations::Base::ParameterError, operation.name) { operation.call(context:, params: params_for(operation)) }
      assert_equal "No such plan", error.message, operation.name
    end
  end

  should "open every plan read to its members, so the walk above refuses for the right reason" do
    [ @editor, @viewer ].each do |member|
      OPERATIONS.call.select { it.parameters.key?(:plan_id) && it.category == :read }.each do |operation|
        assert_includes operation.call(context: context_for(member), params: params_for(operation)).to_json, @plan_id
      end
    end
  end

  should "shut a member out the moment they leave or are forgotten" do
    @viewer.person.update!(status: "inactive")
    assert_raises(Operations::Base::ParameterError) do
      Operations::TeamPlanning::PlanMembers.call(context: context_for(@viewer), params: { plan_id: @plan_id })
    end
    assert_empty Operations::TeamPlanning::Plans.call(context: context_for(@viewer), params: {})[:plans]
  end

  private

  def outsiders
    person = -> { create(:person, tenant: @tenant) }
    {
      "a tenant admin" => context_for(account(role: :admin, person: person.call)),
      "an Org Graph editor" => context_for(account(role: :member, org_graph_editor: true, person: person.call)),
      "a planner" => context_for(account(role: :member, team_planner: true, person: person.call)),
      "a global admin" => context_for(account(role: :member, person: person.call, global_admin: true)),
      "a member" => context_for(account(role: :member, person: person.call))
    }
  end

  def params_for(operation)
    values = { plan_id: @plan_id, name: "Taken over", person_id: @viewer.person.id, role: "editor", reason: "Curious",
               base_on: "2026-11-14" }
    values.slice(*operation.parameters.keys)
  end

  def stream_size = Rails.configuration.event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).count

  def account(role:, person: create(:person, tenant: @tenant), global_admin: false, **grants)
    create(:tenant_user, tenant: @tenant, user: create(:user, global_admin:), role:, person:, **grants)
  end

  def context_for(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def call(operation, account, **params) = operation.call(context: context_for(account), params:)
end
