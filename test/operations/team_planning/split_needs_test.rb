# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::SplitNeedsTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    org = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    @squads = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    @ada = create(:person, tenant: @tenant, name: "Ada Quill")
    @brook = create(:person, tenant: @tenant, name: "Brook Tamsin")
    structure.define_taxonomy([ { level_id: @squads, name: "Squad" } ], effective_on: "2026-01-01")
    structure.create_unit(@payments, "Payments", level_id: @squads, effective_on: "2026-01-01")
    [ @ada, @brook ].each do
      org.record_person(it.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", title: "Engineer")
      org.set_membership(it.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
    end

    @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
    @outsider = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    @plan_id = call(Operations::TeamPlanning::CreatePlan, @editor, name: "Next year", base_on: "2026-03-02")[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, @editor, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @q1 = call(Operations::TeamPlanning::ForkScenario, @editor, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]

    @creates = plan(Operations::TeamPlanning::SetUnit, name: "Platform", top_level: true, level_id: @squads)
    @platform = TeamPlanningOverride.find_by!(event_id: @creates).subject_id
    @to_platform = place(@brook, @platform)
    @to_payments = place(@ada, @payments)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  should "list each change the scenario makes, oldest first, with the staying change one needs to move across" do
    result = needs

    assert_equal [ @creates, @to_platform, @to_payments ], result[:changes].map { it[:event_id] }
    assert_equal [ [ @brook.id, "assignment" ] ], result[:changes].select { it[:needs].any? }.map { it.values_at(:subject_id, :facet) }
    assert_equal [ { event_id: @creates, subject_id: @platform, facet: "unit" } ], result[:changes][1][:needs]
    assert_equal [ "Ada Quill", "Brook Tamsin" ], result[:names].values_at(@ada.id, @brook.id)
  end

  should "read a choice that takes every need along as one that splits, and one that leaves a need behind as refused" do
    assert_raises(Operations::Base::ParameterError) { split(@to_platform) }

    split(@to_platform, @creates)

    assert_equal [ @to_payments ], needs[:changes].map { it[:event_id] }
  end

  should "name a need no change in effect can meet, so the change can't move" do
    call(Operations::TeamPlanning::ClearChange, @editor, plan_id: @plan_id, scenario_id: @q1, subject_id: @platform, facet: "unit")

    brook = needs[:changes].find { it[:subject_id] == @brook.id }

    assert_equal [ { event_id: nil, subject_id: @platform, facet: "unit" } ], brook[:needs]
    assert_raises(Operations::Base::ParameterError) { split(@to_platform) }
  end

  should "answer a viewer, refuse the baseline as the split does, and refuse anyone outside the plan as an unknown plan" do
    assert_equal 3, needs(@viewer)[:changes].size
    baseline = assert_raises(Operations::Base::ParameterError) { needs(scenario_id: @plan_id) }
    refused = assert_raises(Operations::Base::ParameterError) { split(@to_payments, scenario_id: @plan_id) }
    assert_equal "The baseline can't be split", baseline.message
    assert_equal refused.message, baseline.message
    assert_equal "No such plan", assert_raises(Operations::Base::ParameterError) { needs(@outsider) }.message
  end

  private

  def needs(as = @editor, scenario_id: @q1) = call(Operations::TeamPlanning::SplitNeeds, as, plan_id: @plan_id, scenario_id:)

  def split(*event_ids, scenario_id: @q1)
    call(Operations::TeamPlanning::SplitScenario, @editor, plan_id: @plan_id, scenario_id:, event_ids:, name: "Agreed")
  end

  def plan(operation, **params)
    call(operation, @editor, plan_id: @plan_id, scenario_id: @q1, **params)
    call(Operations::TeamPlanning::History, @editor, plan_id: @plan_id, scenario_id: @q1)[:entries].last[:event_id]
  end

  def place(person, unit_id) = plan(Operations::TeamPlanning::SetAssignment, person_id: person.id, placements: [ { unit_id:, allocation: 1.0 } ])

  def call(operation, account, **params)
    operation.call(context: AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person), params:)
  end
end
