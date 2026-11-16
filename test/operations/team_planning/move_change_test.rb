# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::MoveChangeTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  PAY = { amount: "92000", currency: "aud", period: "year", basis: "full_time" }.freeze

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @holder = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      handler.record_person(@ada.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", level: "3")
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @editor.person_id, role: "editor")
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @q1 = fork(@plan_id, "Q1", ends_on: "2026-06-30")
    @q2 = fork(@q1, "Q2", ends_on: "2026-09-30")
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def call(operation, as: @holder, **params)
    as_tenant { operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:) }
  end

  def fork(parent_id, name, ends_on:)
    call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, parent_id:, relation: "then", name:, ends_on:)[:scenario_id]
  end

  def leave(scenario_id, **params)
    call(Operations::TeamPlanning::SetDeparture, plan_id: @plan_id, scenario_id:, person_id: @ada.id, **params)
  end

  def move(scenario_id = @q1, as: @editor, direction: "later", **params)
    call(Operations::TeamPlanning::MoveChange, as:, plan_id: @plan_id, scenario_id:, subject_id: @ada.id, facet: "departure", direction:, **params)
  end

  def actions(scenario_id) = call(Operations::TeamPlanning::History, plan_id: @plan_id, scenario_id:)[:entries].map { it.values_at(:action, :facet) }

  def refusal(&) = assert_raises(Operations::Base::ParameterError, &).message

  should "move a departure a step later, and answer with the step it reached" do
    leave(@q1)

    assert_equal({ plan_id: @plan_id, scenario_id: @q1, to_scenario_id: @q2, subject_id: @ada.id, facet: "departure", moved: true }, move)
    assert_empty actions(@q1)
    assert_equal [ %w[set departure], %w[move departure] ], actions(@q2)
  end

  should "let an editor without the see-pay right move a change, and leave the pay change where it was" do
    leave(@q1)
    call(Operations::TeamPlanning::SetActualPay, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, **PAY)

    move

    assert_equal [ [ "set", "data:pay" ] ], actions(@q1)
    assert_equal [ %w[set departure], %w[move departure] ], actions(@q2)
  end

  should "take the whole move back with one undo in the step it reached" do
    leave(@q1)
    move

    call(Operations::TeamPlanning::UndoChange, as: @editor, plan_id: @plan_id, scenario_id: @q2)

    assert_equal [ %w[set departure] ], actions(@q1)
  end

  should "pass on the plan's refusals, and refuse a viewer as an unknown plan" do
    leave(@q1, leaves_on: "2026-05-01")

    assert_match "baseline", refusal { move(direction: "earlier") }
    assert_match "2026-05-01", refusal { move }
    leave(@q2)
    assert_match "already changes this", refusal { move }
    assert_match "No such plan", refusal { move(as: @viewer) }
    assert_match "to_scenario_id must be a UUID", refusal { move(to_scenario_id: "q3") }
  end

  should "refuse a facet or direction the plan can't move, and publish the ones it can" do
    leave(@q1)

    assert_match "facet must be one of", refusal { call(Operations::TeamPlanning::MoveChange, as: @editor, plan_id: @plan_id, scenario_id: @q1, subject_id: @ada.id, facet: "level", direction: "later") }
    assert_match "direction must be one of", refusal { move(direction: "sideways") }
    properties = Mcp::OperationToTool.call(Operations::TeamPlanning::MoveChange)[:inputSchema][:properties]
    assert_equal({ "facet" => %w[assignment position departure], "direction" => %w[earlier later] }, properties.slice("facet", "direction").transform_values { it[:enum] })
  end

  should "be a write an MCP client asks before making" do
    assert_equal [ :write, :mcp_client ], [ Operations::TeamPlanning::MoveChange.category, Operations::TeamPlanning::MoveChange.approval ]
  end
end
