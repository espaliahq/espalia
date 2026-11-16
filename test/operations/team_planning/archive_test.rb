# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::ArchiveTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    travel_to Time.utc(2026, 3, 10, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @editor = create(:tenant_user, tenant: @tenant, team_planner: true, person: create(:person, tenant: @tenant, name: "Edie Marsh"))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant, name: "Vic Arden"))
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    @q1 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @live_id = call(Operations::TeamPlanning::CreatePlan, name: "Live", base_on: "2026-03-02")[:plan_id]
    travel_to Time.utc(2026, 3, 12, 9)
    assert_equal({ plan_id: @plan_id, archived: true }, call(Operations::TeamPlanning::ArchivePlan, plan_id: @plan_id))
  end

  teardown { travel_back }

  def call(operation, as: @editor, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:)
    end
  end

  def refusal(operation, as: @editor, **params)
    assert_raises(Operations::Base::ParameterError) { call(operation, as:, **params) }.message
  end

  should "say who archived the plan and when" do
    assert_equal({ on: "2026-03-12", by_id: @editor.person_id, by_name: "Edie Marsh", priced_on: "2026-03-12" },
                 call(Operations::TeamPlanning::Plan, as: @viewer, plan_id: @plan_id)[:archived])
  end

  should "list live plans by default, and archived or all on request" do
    names = ->(state = nil) { call(Operations::TeamPlanning::Plans, **({ state: } if state).to_h)[:plans].map { [ it[:name], it[:archived_on] ] } }

    assert_equal [ [ "Live", nil ] ], names.call
    assert_equal [ [ "Next year", "2026-03-12" ] ], names.call("archived")
    assert_equal [ [ "Live", nil ], [ "Next year", "2026-03-12" ] ], names.call("all")
    assert_match "state must be one of", refusal(Operations::TeamPlanning::Plans, state: "gone")
  end

  should "say it was not checked rather than list nothing" do
    unchecked = { checked: false, archived_on: "2026-03-12",
                  note: "This plan was archived on 12 March 2026, so it stopped being checked against the organisation that day. " \
                        "Restore it to check it again." }

    assert_equal({ plan_id: @plan_id, **unchecked, changes: [], names: {} }, call(Operations::TeamPlanning::Drift, plan_id: @plan_id))
    assert_equal({ plan_id: @plan_id, scenario_id: @q1, **unchecked, statuses: [], names: {} },
                 call(Operations::TeamPlanning::Status, plan_id: @plan_id, scenario_id: @q1))
    assert_equal({ plan_id: @plan_id, scenario_id: @q1, **unchecked, items: [], names: {} },
                 call(Operations::TeamPlanning::Attention, plan_id: @plan_id, scenario_id: @q1))
    assert_equal TeamPlanning::PlanAggregate::ARCHIVED, refusal(Operations::TeamPlanning::RebasePreview, plan_id: @plan_id)
  end

  should "refuse to read or hold actual pay from a file" do
    assert_equal TeamPlanning::PlanAggregate::ARCHIVED,
                 refusal(Operations::TeamPlanning::UploadActualPay, plan_id: @plan_id, scenario_id: @plan_id, basis: "full_time",
                                                                    csv: "person,amount,currency,period\n")
  end

  should "still refuse a scenario the plan doesn't have" do
    stranger = SecureRandom.uuid_v7
    assert_equal "This plan has no such scenario", refusal(Operations::TeamPlanning::Status, plan_id: @plan_id, scenario_id: stranger)
    assert_equal "This plan has no such scenario", refusal(Operations::TeamPlanning::Attention, plan_id: @plan_id, scenario_id: stranger)
    assert_equal [], call(Operations::TeamPlanning::Attention, plan_id: @plan_id)[:items]
  end

  PRICING_READS = [ [ Operations::TeamPlanning::Cost, :q1 ], [ Operations::TeamPlanning::Capacity, :q1 ], [ Operations::TeamPlanning::Forecast, :q1 ],
                    [ Operations::TeamPlanning::Budget, :q1 ], [ Operations::TeamPlanning::Funding, :q1 ], [ Operations::TeamPlanning::BudgetLines, :q1 ],
                    [ Operations::TeamPlanning::ScenarioCosts, nil ] ].freeze

  def pricing_notes(plan_id, scenario_id)
    PRICING_READS.map do |operation, scenario_read|
      result = call(operation, plan_id:, **({ scenario_id: } if scenario_read).to_h)
      [ operation.name, result.values_at(:archived_on, :priced_on, :note) ]
    end
  end

  should "say its figures are priced as on its archive day, with framework roles and levels read live" do
    note = "Priced as on 12 March 2026, when this plan was archived: pay bands, exchange rates, budget lines and rules as they " \
           "stood then. Framework roles and levels are read as they are now."

    pricing_notes(@plan_id, @q1).each { |name, values| assert_equal [ "2026-03-12", "2026-03-12", note ], values, name }
    assert_not call(Operations::TeamPlanning::Cost, plan_id: @live_id, scenario_id: @live_id).key?(:archived_on)
  end

  should "say a plan archived without a copy of its prices still uses today's" do
    call(Operations::TeamPlanning::RestorePlan, plan_id: @plan_id)
    PlanKeyStore.stub(:available?, false) { call(Operations::TeamPlanning::ArchivePlan, plan_id: @plan_id) }
    note = "This plan was archived on 12 March 2026. Its figures still use today's pay bands, exchange rates, budget lines and rules."

    pricing_notes(@plan_id, @q1).each { |name, values| assert_equal [ "2026-03-12", nil, note ], values, name }
    assert_nil call(Operations::TeamPlanning::Plan, plan_id: @plan_id)[:archived][:priced_on]
  end

  should "refuse changes until an editor restores it, and check it again after" do
    assert_equal TeamPlanning::PlanAggregate::ARCHIVED, refusal(Operations::TeamPlanning::RenamePlan, plan_id: @plan_id, name: "Later")
    assert_equal "No such plan", refusal(Operations::TeamPlanning::RestorePlan, as: @viewer, plan_id: @plan_id)

    assert_equal({ plan_id: @plan_id, archived: false }, call(Operations::TeamPlanning::RestorePlan, plan_id: @plan_id))
    assert_nil call(Operations::TeamPlanning::Plan, plan_id: @plan_id)[:archived]
    assert call(Operations::TeamPlanning::Drift, plan_id: @plan_id)[:checked]
    assert_equal "This plan isn't archived", refusal(Operations::TeamPlanning::RestorePlan, plan_id: @plan_id)
  end

  should "forget a person's sealed values while archived, and keep them forgotten after a restore" do
    call(Operations::TeamPlanning::RestorePlan, plan_id: @plan_id)
    call(Operations::TeamPlanning::SetPlannedLevel, plan_id: @plan_id, scenario_id: @q1, person_id: @viewer.person_id,
                                                    level: "E5", note: "Ready since the launch")
    call(Operations::TeamPlanning::ArchivePlan, plan_id: @plan_id)
    note = -> { call(Operations::TeamPlanning::History, plan_id: @plan_id, scenario_id: @q1)[:entries].find { it[:action] == "set" }[:note] }
    assert_equal({ value: "Ready since the launch" }, note.call)

    ActsAsTenant.with_tenant(@tenant) { PlanKeyStore.new.destroy_person(@viewer.person_id) }
    assert_equal({ removed: true }, note.call)

    call(Operations::TeamPlanning::RestorePlan, plan_id: @plan_id)
    assert_equal({ removed: true }, note.call)
  end

  should "refuse a viewer's archive, as a member or not" do
    assert_equal "No such plan", refusal(Operations::TeamPlanning::ArchivePlan, as: @viewer, plan_id: @live_id)

    call(Operations::TeamPlanning::AddPlanMember, plan_id: @live_id, person_id: @viewer.person_id, role: "viewer")
    assert_equal "No such plan", refusal(Operations::TeamPlanning::ArchivePlan, as: @viewer, plan_id: @live_id)
    assert_nil call(Operations::TeamPlanning::Plan, plan_id: @live_id)[:archived]
  end
end
