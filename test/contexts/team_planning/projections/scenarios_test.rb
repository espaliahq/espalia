# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class TeamPlanning::Projections::ScenariosTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @person = create(:person, tenant: @tenant)
    user = create(:user)
    tenant_user = create(:tenant_user, tenant: @tenant, user:, person: @person, role: :admin)
    @handler = TeamPlanning::CommandHandler.new(actor: AuthorizationContext.new(user:, tenant_user:, person: @person))
    @plan_id = SecureRandom.uuid_v7
    @handler.create_plan(@plan_id, name: "Next year", base_on: "2027-01-01")
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def fork(parent_id = @plan_id, relation: "then", name: "Q1", ends_on: nil)
    SecureRandom.uuid_v7.tap do |id|
      @handler.fork_scenario(@plan_id, id, parent_id:, relation:, name:, ends_on:)
    end
  end

  def periods
    TeamPlanningScenario.where(plan_id: @plan_id).order(:created_at, :id)
      .pluck(:name, :starts_on, :ends_on).map { |name, starts_on, ends_on| [ name, starts_on.iso8601, ends_on&.iso8601 ] }
  end

  should "give every plan a baseline on its base date" do
    baseline = TeamPlanningScenario.find(@plan_id)
    assert baseline.baseline?
    assert_equal [ "Baseline", Date.new(2027, 1, 1), nil, nil ], [ baseline.name, baseline.starts_on, baseline.ends_on, baseline.relation ]
  end

  should "keep each period as the tree gives it, as ends move" do
    q1 = fork(ends_on: "2027-03-31")
    lean = fork(q1, relation: "instead", name: "Lean Q1")
    fork(q1, name: "Q2", ends_on: "2027-06-30")
    fork(lean, name: "Lean Q2", ends_on: "2027-05-31")
    row = TeamPlanningScenario.find(lean)
    assert_equal [ q1, "instead", @person.id ], [ row.parent_id, row.relation, row.forked_by_id ]

    @handler.set_scenario_period(@plan_id, q1, ends_on: "2027-02-28")

    assert_equal [ [ "Baseline", "2027-01-01", nil ], [ "Q1", "2027-01-01", "2027-02-28" ], [ "Lean Q1", "2027-01-01", "2027-02-28" ],
                   [ "Q2", "2027-03-01", "2027-06-30" ], [ "Lean Q2", "2027-03-01", "2027-05-31" ] ], periods
  end

  should "follow a moved end in a plan that has no baseline row yet" do
    TeamPlanningScenario.find(@plan_id).delete
    q1 = fork(ends_on: "2027-03-31")
    fork(q1, name: "Q2", ends_on: "2027-06-30")

    @handler.set_scenario_period(@plan_id, q1, ends_on: "2027-02-28")

    assert_equal [ [ "Q1", "2027-01-01", "2027-02-28" ], [ "Q2", "2027-03-01", "2027-06-30" ] ], periods
  end

  should "drop a removed scenario, and every scenario of a deleted plan" do
    q1 = fork(ends_on: "2027-03-31")
    q2 = fork(q1, name: "Q2", ends_on: "2027-06-30")
    @handler.remove_scenario(@plan_id, q2)
    assert_equal %w[Baseline Q1], periods.map(&:first)

    @handler.delete_plan(@plan_id)
    assert_empty periods
  end

  context "rebuild contract" do
    should "reset! + replay produce identical read-model state, including the stable ids" do
      q1 = fork(ends_on: "2027-03-31")
      fork(q1, relation: "instead", name: "Lean Q1")
      q2 = fork(q1, name: "Q2", ends_on: "2027-06-30")
      @handler.set_scenario_period(@plan_id, q1, ends_on: "2027-04-30")
      @handler.remove_scenario(@plan_id, q2)
      gone = SecureRandom.uuid_v7
      @handler.create_plan(gone, name: "Gone", base_on: "2027-01-01")
      @handler.delete_plan(gone)

      before = snapshot_read_models(TeamPlanning::Projections::Scenarios, @tenant)
      assert_equal 3, before[:scenarios].size

      TeamPlanning::Projections::Scenarios.reset!(tenant: @tenant)
      assert_equal 0, TeamPlanningScenario.count
      Projections::Replayer.replay(projection_class: TeamPlanning::Projections::Scenarios, tenant: @tenant)

      assert_equal before, snapshot_read_models(TeamPlanning::Projections::Scenarios, @tenant)
    end
  end

  should "keep one tenant's scenarios out of another's" do
    fork(ends_on: "2027-03-31")
    other = create(:tenant)
    ActsAsTenant.with_tenant(other) { assert_empty TeamPlanningScenario.all }
  end
end
