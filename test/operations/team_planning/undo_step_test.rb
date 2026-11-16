# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::UndoStepTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2026-01-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  PAY = { amount: "92417", currency: "aud", period: "year", basis: "full_time" }.freeze

  setup do
    @tenant = create(:tenant)
    departments = SecureRandom.uuid_v7
    @engineering, @sales = Array.new(2) { SecureRandom.uuid_v7 }

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
      structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: "2026-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: departments, effective_on: "2026-01-01")
      structure.create_unit(@sales, "Sales", level_id: departments, effective_on: "2026-01-01")

      people = OrgGraph::CommandHandler.new(actor: SYSTEM)
      @ada, @cy = [ [ "Ada Quill", @engineering ], [ "Cy Rowe", @sales ] ].map do |name, unit|
        create(:person, tenant: @tenant, name:).tap do |person|
          people.record_person(person.id, **ESPALIA, employment_status: "employed", level: "3")
          people.set_membership(person.id, unit, **ESPALIA, allocation: 1.0)
        end
      end

      @holder = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
    end
    @plan_id = call(:CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    call(:AddPlanMember, plan_id: @plan_id, person_id: @editor.person_id, role: "editor")
    call(:AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    call(:GrantSeePay, plan_id: @plan_id, person_id: @editor.person_id)
    @q1 = call(:ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def call(operation, as: @holder, **params)
    context = AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person)
    as_tenant { "Operations::TeamPlanning::#{operation}".constantize.call(context:, params:) }
  end

  def step(as: @editor, scenario_id: @q1) = call(:UndoStep, as:, plan_id: @plan_id, scenario_id:)

  def set_level(level, as: @editor, person: @ada) = call(:SetPlannedLevel, as:, plan_id: @plan_id, scenario_id: @q1, person_id: person.id, level:)

  def set_pay(as: @editor) = call(:SetActualPay, as:, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, **PAY)

  def leave(on) = call(:SetDeparture, as: @editor, plan_id: @plan_id, scenario_id: @q1, person_id: @ada.id, leaves_on: on)

  def latest = call(:History, plan_id: @plan_id, scenario_id: @q1)[:entries].last[:event_id]

  def clearable(as: @editor, scenario_id: @q1)
    call(:Status, as:, plan_id: @plan_id, scenario_id:)[:statuses].to_h { [ it[:facet], it[:clearable] ] }
  end

  def withdraw_see_pay = call(:WithdrawSeePay, plan_id: @plan_id, person_id: @editor.person_id)

  should "name the caller's latest change as undo, and once undone, as redo" do
    set_level("4")
    event_id = latest
    expected = { event_id:, action: "set", subject_id: @ada.id, subject: "Ada Quill", facet: "level", scenario_id: @q1 }

    assert_equal({ plan_id: @plan_id, scenario_id: @q1, undo: expected, redo: nil }, step)
    call(:UndoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1)
    assert_equal({ plan_id: @plan_id, scenario_id: @q1, undo: nil, redo: expected }, step)
  end

  should "name the caller's latest date edit as undo, and once undone, as redo, with no subject or facet" do
    call(:SetScenarioPeriod, as: @editor, plan_id: @plan_id, scenario_id: @q1, ends_on: "2026-09-30")
    event_id = step[:undo][:event_id]
    expected = { event_id:, action: "dates", subject_id: nil, subject: nil, facet: nil, scenario_id: @q1 }

    assert_equal expected, step[:undo]
    call(:UndoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1)
    assert_equal({ plan_id: @plan_id, scenario_id: @q1, undo: nil, redo: expected }, step)
  end

  should "offer the date edit before a later change once that change is undone" do
    call(:SetScenarioPeriod, as: @editor, plan_id: @plan_id, scenario_id: @q1, ends_on: "2026-09-30")
    set_level("4")
    assert_equal "set", step[:undo][:action]

    call(:UndoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1)
    assert_equal "dates", step[:undo][:action]
  end

  should "call a clear a clear" do
    set_level("4")
    call(:ClearChange, as: @editor, plan_id: @plan_id, scenario_id: @q1, subject_id: @ada.id, facet: "level")

    assert_equal [ "clear", "level" ], step[:undo].values_at(:action, :facet)
  end

  should "leave someone else's change out" do
    set_level("4", as: @holder)

    assert_nil step[:undo]
  end

  should "offer a pay change to a member with the see-pay right, never naming the amount" do
    set_pay

    assert_equal [ "set", "data:pay" ], step[:undo].values_at(:action, :facet)
    assert_not_includes step.to_json, PAY[:amount]
  end

  should "offer the latest other change as undo once the see-pay right is withdrawn" do
    set_level("4")
    level_id = latest
    set_pay
    withdraw_see_pay

    assert_equal level_id, step[:undo][:event_id]
    assert_equal level_id, call(:UndoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1)[:event_id]
  end

  should "offer nothing, and hint at nothing, when a pay change is the only one left" do
    set_pay
    withdraw_see_pay

    assert_equal({ plan_id: @plan_id, scenario_id: @q1, undo: nil, redo: nil }, step)
  end

  should "offer the latest other redo once the see-pay right is withdrawn" do
    set_pay
    set_level("4")
    level_id = latest
    2.times { call(:UndoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1) }
    assert_equal "data:pay", step[:redo][:facet]

    withdraw_see_pay
    assert_equal level_id, step[:redo][:event_id]
    assert_equal level_id, call(:RedoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1)[:event_id]
  end

  should "offer no redo, and hint at none, when a pay change is the only one left" do
    set_pay
    call(:UndoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1)
    withdraw_see_pay

    assert_nil step[:redo]
  end

  should "offer nothing to a viewer, in Today, on a frozen plan or on an archived one" do
    set_level("4")
    nothing = { undo: nil, redo: nil }

    assert_equal nothing, step(as: @viewer).slice(:undo, :redo)
    call(:SetPlannedLevel, as: @editor, plan_id: @plan_id, scenario_id: @plan_id, person_id: @ada.id, level: "5")
    assert_equal nothing, step(scenario_id: @plan_id).slice(:undo, :redo)
    PlanPolicy.stub(:frozen?, true) { assert_equal nothing, step.slice(:undo, :redo) }
    call(:ArchivePlan, plan_id: @plan_id)
    assert_equal nothing, step.slice(:undo, :redo)
  end

  should "offer no undo that would bring back a change about someone who has left a scoped plan's units, as the operation refuses it" do
    set_level("4")
    set_level("5")
    call(:SetPlanScope, plan_id: @plan_id, unit_ids: [ @engineering ])
    assert_equal @ada.id, step[:undo][:subject_id]

    as_tenant { OrgGraph::CommandHandler.new(actor: SYSTEM).move_membership(@ada.id, @engineering, @sales, effective_on: "2026-01-15") }

    assert_nil step[:undo]
    assert_raises(Operations::Base::ParameterError) { call(:UndoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1) }
  end

  should "offer no redo of a change about someone who has left a scoped plan's units" do
    set_level("4")
    call(:SetPlanScope, plan_id: @plan_id, unit_ids: [ @engineering ])
    call(:UndoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1)
    assert_equal @ada.id, step[:redo][:subject_id]

    as_tenant { OrgGraph::CommandHandler.new(actor: SYSTEM).move_membership(@ada.id, @engineering, @sales, effective_on: "2026-01-15") }

    assert_nil step[:redo]
    assert_raises(Operations::Base::ParameterError) { call(:RedoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1) }
  end

  should "offer no undo that would bring back a departure outside the step's dates, as the operation refuses it" do
    leave("2026-05-15")
    leave("2026-04-01")
    call(:SetScenarioPeriod, plan_id: @plan_id, scenario_id: @q1, ends_on: "2026-04-30")

    assert_nil step[:undo]
    assert_raises(Operations::Base::ParameterError) { call(:UndoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1) }
  end

  should "offer no redo of a departure outside the step's dates" do
    leave("2026-05-15")
    call(:UndoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1)
    call(:SetScenarioPeriod, plan_id: @plan_id, scenario_id: @q1, ends_on: "2026-04-30")

    assert_nil step[:redo]
    assert_raises(Operations::Base::ParameterError) { call(:RedoChange, as: @editor, plan_id: @plan_id, scenario_id: @q1) }
  end

  should "refuse an unknown scenario, and someone not in the plan" do
    outsider = as_tenant { create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant)) }

    assert_equal "This plan has no such scenario", assert_raises(Operations::Base::ParameterError) { step(scenario_id: SecureRandom.uuid_v7) }.message
    assert_equal "No such plan", assert_raises(Operations::Base::ParameterError) { step(as: outsider) }.message
  end

  context "clearable on the status read" do
    setup do
      set_level("4")
      set_pay
    end

    should "mark a change the scenario makes itself, to an editor and a pay holder" do
      assert_equal({ "level" => true, "data:pay" => true }, clearable)
      assert_equal({ "level" => true, "data:pay" => true }, clearable(as: @holder))
    end

    should "mark nothing for a viewer, in Today, or in a step that only inherits the change" do
      q2 = call(:ForkScenario, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2", ends_on: "2026-09-30")[:scenario_id]

      assert_equal [ false ], clearable(as: @viewer).values.uniq
      call(:SetPlannedLevel, as: @editor, plan_id: @plan_id, scenario_id: @plan_id, person_id: @cy.id, level: "5")
      assert_equal({ "level" => false }, clearable(scenario_id: @plan_id))
      assert_equal [ false ], clearable(scenario_id: q2).values.uniq
    end

    should "mark nothing on an archived plan, which has no statuses to clear" do
      call(:ArchivePlan, plan_id: @plan_id)

      assert_empty clearable
      assert_empty clearable(as: @holder)
    end

    should "not mark a pay change once the see-pay right is withdrawn" do
      withdraw_see_pay

      assert_equal({ "level" => true, "data:pay" => false }, clearable)
    end

    should "not mark a change about someone who has left a scoped plan's units" do
      call(:SetPlanScope, plan_id: @plan_id, unit_ids: [ @engineering ])
      assert_equal [ true ], clearable.values.uniq

      as_tenant { OrgGraph::CommandHandler.new(actor: SYSTEM).move_membership(@ada.id, @engineering, @sales, effective_on: "2026-01-15") }
      assert_equal [ false ], clearable.values.uniq
    end
  end
end
