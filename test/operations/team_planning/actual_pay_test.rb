# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::ActualPayTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  PAY = { amount: "92000", currency: "aud", period: "year", basis: "full_time" }.freeze
  NO_RIGHT = "Only a member with the see-pay right can change pay"

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @holder = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      handler.record_person(@ada.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", level: "3")
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @editor.person_id, role: "editor")
    @q1 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def call(operation, as: @holder, **params)
    as_tenant { operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:) }
  end

  def set_pay(as: @holder, **pay) = call(Operations::TeamPlanning::SetActualPay, as:, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, **PAY, **pay)

  def refusal(as: @holder, &) = assert_raises(Operations::Base::ParameterError, &).message

  def history = call(Operations::TeamPlanning::History, plan_id: @plan_id, scenario_id: @q1)

  should "hold pay for a holder, normalised, and answer with it" do
    assert_equal({ plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id,
                   pay: { "amount" => "92000", "currency" => "AUD", "period" => "year", "basis" => "full_time" } },
                 set_pay(amount: "92000.00"))
  end

  should "refuse pay that can't be pay, without naming the value" do
    { { amount: "-417" } => "A pay amount is a number above 0, with at most 4 decimal places",
      { amount: "9,200" } => "A pay amount is a number above 0, with at most 4 decimal places",
      { currency: "XYZ" } => "A pay currency is a three-letter ISO 4217 code",
      { period: "hour", basis: "actual" } => "An hourly amount is a rate, which FTE scales, so its basis is full_time" }.each do |bad, message|
      error = refusal { set_pay(**bad) }
      assert_equal message, error
      assert_not_includes error, bad[:amount] if bad[:amount]
    end
    assert_equal "missing required parameter: basis", refusal { call(Operations::TeamPlanning::SetActualPay, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, **PAY.except(:basis)) }
  end

  should "refuse pay to a non-holder whose change names the field with a string key" do
    context = AuthorizationContext.new(user: @editor.user, tenant_user: @editor, person: @editor.person)
    error = assert_raises(TeamPlanning::Error) do
      as_tenant do
        TeamPlanning::CommandHandler.new(actor: context).set_change(@plan_id, TeamPlanning::Events::PlanDataSet, scenario_id: @q1,
                                                                    subject_id: @ada.id, end_state: { "field" => "pay", "value" => PAY })
      end
    end
    assert_equal NO_RIGHT, error.message
  end

  should "refuse pay through the generic plan value tool" do
    assert_equal "Pay has its own tool, team_planning_set_actual_pay",
                 refusal { call(Operations::TeamPlanning::SetPlanValue, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, field: "pay", value: "1") }
  end

  should "refuse an editor without the see-pay right to write, clear, undo, redo or note pay" do
    assert_equal NO_RIGHT, refusal { set_pay(as: @editor) }

    set_pay
    pay_change = history[:entries].find { it[:facet] == "data:pay" }
    assert_equal NO_RIGHT, refusal { call(Operations::TeamPlanning::ClearChange, as: @editor, plan_id: @plan_id, scenario_id: @q1, subject_id: @ada.id, facet: "data:pay") }
    assert_equal NO_RIGHT, refusal { call(Operations::TeamPlanning::UndoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1, event_id: pay_change[:event_id]) }
    assert_equal NO_RIGHT, refusal { call(Operations::TeamPlanning::NoteChange, as: @editor, plan_id: @plan_id, scenario_id: @q1, event_id: pay_change[:event_id], note: "Agreed") }

    call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @q1, event_id: pay_change[:event_id])
    assert_equal NO_RIGHT, refusal { call(Operations::TeamPlanning::RedoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1, event_id: pay_change[:event_id]) }
  end

  should "let a holder clear, undo and redo pay" do
    set_pay
    call(Operations::TeamPlanning::ClearChange, plan_id: @plan_id, scenario_id: @q1, subject_id: @ada.id, facet: "data:pay")
    assert_equal({ undone: true }, call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @q1).slice(:undone))
    call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @q1)
    assert_equal({ redone: true }, call(Operations::TeamPlanning::RedoChange, plan_id: @plan_id, scenario_id: @q1).slice(:redone))
  end

  should "refuse a former holder once the right is withdrawn" do
    call(Operations::TeamPlanning::GrantSeePay, plan_id: @plan_id, person_id: @editor.person_id)
    set_pay(as: @editor)
    call(Operations::TeamPlanning::WithdrawSeePay, plan_id: @plan_id, person_id: @editor.person_id)

    pay_change = history[:entries].find { it[:facet] == "data:pay" }[:event_id]
    assert_equal NO_RIGHT, refusal { call(Operations::TeamPlanning::UndoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1, event_id: pay_change) }
  end

  should "pass over pay on a former holder's Undo and Redo, to the change they may still touch" do
    call(Operations::TeamPlanning::GrantSeePay, plan_id: @plan_id, person_id: @editor.person_id)
    call(Operations::TeamPlanning::SetPlanValue, as: @editor, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, field: "level", value: "4")
    set_pay(as: @editor)
    level_change = history[:entries].find { it[:facet] == "data:level" }[:event_id]
    call(Operations::TeamPlanning::UndoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1, event_id: level_change)
    call(Operations::TeamPlanning::UndoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1)
    call(Operations::TeamPlanning::RedoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1)
    call(Operations::TeamPlanning::WithdrawSeePay, plan_id: @plan_id, person_id: @editor.person_id)

    undo_last = -> { call(Operations::TeamPlanning::UndoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1) }
    redo_last = -> { call(Operations::TeamPlanning::RedoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1) }
    assert_equal level_change, redo_last.call[:event_id]
    assert_equal level_change, undo_last.call[:event_id]
    assert_equal "You have nothing here to undo", refusal { undo_last.call }
  end

  should "never defer to an in-app approval, which would store pay in clear" do
    assert_equal :mcp_client, Operations::TeamPlanning::SetActualPay.approval
  end
end
