# frozen_string_literal: true

require "test_helper"

# An unknown allocation and a cleared level come only from following the Org
# Graph, so neither the operations nor MCP let anyone set one
# ([#363](https://github.com/espaliahq/espalia/issues/363)).
class TeamPlanningFollowOnlyValuesTest < ActionDispatch::IntegrationTest
  setup do
    travel_to Time.utc(2026, 2, 1, 9)
    @tenant = create(:tenant)
    @application = Mcp::Application.create!(name: "Test MCP Client", redirect_uri: "https://client.example/callback",
                                            scopes: "read write", confidential: false)
    @unit_id = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      squads = SecureRandom.uuid_v7
      structure.define_taxonomy([ { level_id: squads, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@unit_id, "Payments", level_id: squads, effective_on: "2026-01-01")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .record_person(@ada.id, provider: "espalia", effective_on: "2026-02-01", employment_status: "employed", level: "3")
      @plan_id = operation(:CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    end
    @person = { plan_id: @plan_id, scenario_id: @plan_id, person_id: @ada.id }
  end

  should "refuse an unknown allocation and a blank level from the operations" do
    [ { allocation: nil }, {} ].each do |placement|
      assert_equal "An allocation is above 0 and at most 1",
                   refusal(:SetAssignment, placements: [ { unit_id: @unit_id, **placement } ]), placement.to_s
    end
    [ "", "   " ].each { assert_equal "level can't be blank", refusal(:SetPlannedLevel, level: it), it.inspect }
    assert_equal "missing required parameter: level", refusal(:SetPlannedLevel, level: nil)
    assert_empty history
  end

  should "refuse an unknown allocation and a blank level over MCP" do
    assert_mcp_refused "team_planning_set_assignment", placements: [ { unit_id: @unit_id, allocation: nil } ]
    assert_mcp_refused "team_planning_set_planned_level", level: "   "
    assert_empty history
  end

  private

  def operation(name, **params)
    ActsAsTenant.with_tenant(@tenant) do
      "Operations::TeamPlanning::#{name}".constantize.call(
        context: AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person), params:
      )
    end
  end

  def refusal(name, **params) = assert_raises(Operations::Base::ParameterError) { operation(name, **@person, **params) }.message

  def history = operation(:History, plan_id: @plan_id, scenario_id: @plan_id)[:entries]

  def assert_mcp_refused(tool, **arguments)
    token = Mcp::AccessToken.create!(application: @application, resource_owner_id: @admin.user_id, tenant_id: @tenant.id,
                                     scopes: "read write", expires_in: 3600)
    post mcp_server_path,
         params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: tool, arguments: { **@person, **arguments } } }.to_json,
         headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token.token}" }

    assert_response :success
    assert_equal(-32602, JSON.parse(response.body).dig("error", "code"), response.body)
  end
end
