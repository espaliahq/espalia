# frozen_string_literal: true

require "test_helper"

class TeamPlanning::CommandHandlerScenariosTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @editor = context_for(create(:person, tenant: @tenant), role: :admin)
    @viewer = context_for(create(:person, tenant: @tenant))
    @plan_id = SecureRandom.uuid_v7
    handler(@editor).create_plan(@plan_id, name: "Next year", base_on: "2027-01-01")
    handler(@editor).add_member(@plan_id, @viewer.person.id, role: "viewer")
  end

  teardown { ActsAsTenant.current_tenant = nil }

  should "let an editor fork, rename, move and remove a scenario in the plan's stream, naming who did each" do
    q1 = SecureRandom.uuid_v7
    handler(@editor).fork_scenario(@plan_id, q1, parent_id: @plan_id, relation: "then", name: "Q1", ends_on: "2027-03-31")
    handler(@editor).rename_scenario(@plan_id, q1, name: "First quarter")
    handler(@editor).set_scenario_period(@plan_id, q1, ends_on: "2027-02-28")
    handler(@editor).remove_scenario(@plan_id, q1)

    events = event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).to_a.last(4)
    assert_equal [ TeamPlanning::Events::ScenarioForked, TeamPlanning::Events::ScenarioRenamed,
                   TeamPlanning::Events::ScenarioPeriodSet, TeamPlanning::Events::ScenarioRemoved ], events.map(&:class)
    assert_equal [ @editor.person.id ] * 4,
                 events.map { it.data.values_at(:forked_by_id, :renamed_by_id, :set_by_id, :removed_by_id).compact.sole }
    assert(events.all? { it.metadata[:tenant_id] == @tenant.id })
  end

  should "read as missing to a viewer, an outsider, and anyone once every editor has gone" do
    q1 = SecureRandom.uuid_v7
    handler(@editor).fork_scenario(@plan_id, q1, parent_id: @plan_id, relation: "then", name: "Q1", ends_on: "2027-03-31")
    outsider = context_for(create(:person, tenant: @tenant), role: :admin)
    commands = lambda do |actor|
      [ -> { handler(actor).fork_scenario(@plan_id, SecureRandom.uuid_v7, parent_id: q1, relation: "instead", name: "Mine") },
        -> { handler(actor).rename_scenario(@plan_id, q1, name: "Mine") },
        -> { handler(actor).set_scenario_period(@plan_id, q1, ends_on: "2027-04-30") },
        -> { handler(actor).remove_scenario(@plan_id, q1) } ]
    end

    [ @viewer, outsider ].each do |actor|
      commands.call(actor).each { assert_equal "No such plan", assert_raises(TeamPlanning::Error, &it).message }
    end

    @editor.person.update!(status: "inactive")
    commands.call(@editor).each { assert_equal "No such plan", assert_raises(TeamPlanning::Error, &it).message }
    assert_equal 1, event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).of_type([ TeamPlanning::Events::ScenarioForked ]).count
  end

  should "let an editor move the base, moving the first step and its alternative and noting it in the baseline's history" do
    q1 = SecureRandom.uuid_v7
    lean = SecureRandom.uuid_v7
    handler(@editor).fork_scenario(@plan_id, q1, parent_id: @plan_id, relation: "then", name: "Q1", ends_on: "2027-03-31")
    handler(@editor).fork_scenario(@plan_id, lean, parent_id: q1, relation: "instead", name: "Lean Q1")
    assert_equal "No such plan",
                 assert_raises(TeamPlanning::Error) { handler(@viewer).rebase_plan(@plan_id, base_on: "2027-02-01", expected_base_on: "2027-01-01", conflicts: []) }.message

    handler(@editor).rebase_plan(@plan_id, base_on: "2027-02-01", expected_base_on: "2027-01-01", conflicts: [])

    assert_equal Date.new(2027, 2, 1), TeamPlanningPlan.find(@plan_id).base_on
    assert_equal [ Date.new(2027, 2, 1) ] * 3, TeamPlanningScenario.where(id: [ @plan_id, q1, lean ]).pluck(:starts_on)
    entry = TeamPlanningHistoryEntry.find_by!(scenario_id: @plan_id)
    assert_equal [ "rebase", @editor.person.id, { "base_on" => "2027-02-01", "previous_base_on" => "2027-01-01", "conflicts" => [] } ],
                 [ entry.action, entry.actor_id, entry.end_state ]
  end

  should "refuse a scenario in a deleted plan" do
    handler(@editor).delete_plan(@plan_id)
    error = assert_raises(TeamPlanning::Error) do
      handler(@editor).fork_scenario(@plan_id, SecureRandom.uuid_v7, parent_id: @plan_id, relation: "then", name: "Q1", ends_on: "2027-03-31")
    end
    assert_equal "This plan has been deleted", error.message
  end

  private

  def handler(actor) = TeamPlanning::CommandHandler.new(actor:)

  def event_store = Rails.configuration.event_store

  def context_for(person, role: :member)
    user = create(:user)
    tenant_user = create(:tenant_user, tenant: @tenant, user:, person:, role:)
    AuthorizationContext.new(user:, tenant_user:, person:)
  end
end
