# frozen_string_literal: true

require "test_helper"

# Team Planning's today is the tenant's own day (#469). At 09:00 in Sydney
# UTC is still on the day before, and a plan made, updated or archived then
# takes Sydney's date.
class TeamPlanningTenantTodayTest < ActiveSupport::TestCase
  SYSTEM = OrgGraph::Authorization::SYSTEM
  SYDNEY_9AM_17TH = Time.utc(2026, 11, 16, 22)

  setup do
    @tenant = create(:tenant, time_zone: "Australia/Sydney")
    travel_to Time.utc(2026, 11, 1, 9)
    ActsAsTenant.with_tenant(@tenant) do
      @squads = SecureRandom.uuid_v7
      @payments = SecureRandom.uuid_v7
      structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
      structure.define_taxonomy([ { level_id: @squads, name: "Squad" } ], effective_on: "2026-10-01")
      structure.create_unit(@payments, "Payments", level_id: @squads, effective_on: "2026-10-01")
      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    end
  end

  def call(operation, **params)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: context, params:)
    end
  end

  def context = AuthorizationContext.new(user: @editor.user, tenant_user: @editor, person: @editor.person)

  def plan(id) = ActsAsTenant.with_tenant(@tenant) { TeamPlanningPlan.find(id) }

  should "start a new plan from the tenant's today" do
    travel_to SYDNEY_9AM_17TH

    assert_equal "2026-11-17", call(Operations::TeamPlanning::CreatePlan, name: "Next year")[:base_on]
  end

  should "start a new plan from yesterday still for a tenant behind UTC" do
    @tenant.update!(time_zone: "America/Los_Angeles")
    travel_to Time.utc(2026, 11, 17, 7, 30)

    assert_equal "2026-11-16", call(Operations::TeamPlanning::CreatePlan, name: "Next year")[:base_on]
  end

  should "update a plan to the tenant's today" do
    plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-11-02")[:plan_id]
    travel_to SYDNEY_9AM_17TH

    result = call(Operations::TeamPlanning::RebasePlan, plan_id:, base_on: "2026-11-02")

    assert_equal "2026-11-17", result[:base_on]
    assert_equal Date.new(2026, 11, 17), plan(plan_id).base_on
  end

  should "read a plan based on the tenant's today as standing on today, not as still to come" do
    plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-11-17")[:plan_id]
    travel_to SYDNEY_9AM_17TH

    error = assert_raises(TeamPlanning::Error) do
      ActsAsTenant.with_tenant(@tenant) { TeamPlanning::RebasePreview.new(context:, plan: plan(plan_id)).call }
    end
    assert_equal "This plan already stands on today, 2026-11-17", error.message
  end

  should "check drift and status up to the tenant's today" do
    plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-11-02")[:plan_id]
    travel_to SYDNEY_9AM_17TH

    ActsAsTenant.with_tenant(@tenant) do
      assert_equal Date.new(2026, 11, 17), TeamPlanning::Drift.new(context:, plan: plan(plan_id)).call.to
      assert_equal Date.new(2026, 11, 17), TeamPlanning::Status.new(context:, plan: plan(plan_id), scenario_id: plan_id).call.on
    end
  end

  should "close a step from the tenant's day after it ends" do
    plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-11-02")[:plan_id]
    step_id = call(Operations::TeamPlanning::ForkScenario, plan_id:, relation: "then", name: "Q4", ends_on: "2026-11-16")[:scenario_id]
    travel_to SYDNEY_9AM_17TH

    step = call(Operations::TeamPlanning::Scenarios, plan_id:)[:scenarios].find { it[:scenario_id] == step_id }
    assert_equal [ "ready_to_close", nil ], step.values_at(:state, :not_closable_because)

    assert_equal "2026-11-16", call(Operations::TeamPlanning::CloseStep, plan_id:, scenario_id: step_id)[:ends_on]
  end

  should "archive a plan on the tenant's today, and keep that day on replay" do
    plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-11-02")[:plan_id]
    travel_to SYDNEY_9AM_17TH
    ActsAsTenant.with_tenant(@tenant) { TeamPlanning::CommandHandler.new(actor: context).archive_plan(plan_id) }

    assert_equal Date.new(2026, 11, 17), plan(plan_id).archived_on

    travel_to Time.utc(2026, 12, 1, 9)
    @tenant.update!(time_zone: "UTC")
    replay(plan_id)

    assert_equal Date.new(2026, 11, 17), plan(plan_id).archived_on
  end

  should "keep the UTC day of an archive written before the tenant had a zone" do
    plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-11-02")[:plan_id]
    travel_to SYDNEY_9AM_17TH
    old_shape = TeamPlanning::Events::PlanArchived.new(data: { plan_id:, archived_by_id: @editor.person_id })
    ActsAsTenant.with_tenant(@tenant) do
      event_store.with_metadata(tenant_id: @tenant.id) do
        event_store.publish(old_shape, stream_name: EventStreamNaming.plan_stream(plan_id), expected_version: :any)
      end
    end

    assert_equal Date.new(2026, 11, 16), plan(plan_id).archived_on
  end

  should "count what the Org Graph learned late in the tenant's day as learned that day" do
    @tenant.update!(time_zone: "America/Los_Angeles")
    person = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant, name: "Ada Quill") }
    travel_to Time.utc(2026, 11, 17, 6)
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::CommandHandler.new(actor: SYSTEM)
        .record_person(person.id, provider: "espalia", effective_on: "2026-11-16", employment_status: "employed", title: "Engineer")
    end

    learned = ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::ChangesBetween.new(context:, from: Date.new(2026, 11, 15), to: Date.new(2026, 11, 16), by: :learned).call.changes
    end

    assert_includes learned.map(&:person_id), person.id
  end

  context "a plan's knowledge cut-off" do
    setup do
      @platform = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: SYSTEM).create_unit(@platform, "Platform", level_id: @squads, effective_on: "2026-10-01")
        @ada = create(:person, tenant: @tenant, name: "Ada Quill")
        org.record_person(@ada.id, provider: "espalia", effective_on: "2026-10-01", employment_status: "employed", title: "Engineer")
        org.set_membership(@ada.id, @payments, provider: "espalia", effective_on: "2026-10-01", allocation: 1.0)
      end
    end

    should "stay where the plan fixed it in Sydney when the zone changes" do
      travel_to Time.utc(2026, 11, 2, 1)
      plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-11-03")[:plan_id]
      ActsAsTenant.with_tenant(@tenant) do
        handler.set_change(plan_id, TeamPlanning::Events::AssignmentSet, scenario_id: plan_id, subject_id: @ada.id,
                                                                          end_state: { placements: [ { unit_id: @platform, allocation: 1.0 } ] })
      end
      # Sydney's 2 November ended at 13:00 UTC; UTC's ends at midnight, LA's at 08:00 on the 3rd.
      learn_move(at: Time.utc(2026, 11, 2, 18))
      travel_to Time.utc(2026, 11, 10, 1)
      ActsAsTenant.with_tenant(@tenant) { handler.archive_plan(plan_id) }

      travel_to Time.utc(2026, 11, 20, 1)
      before = reads(plan_id)

      assert_equal [ @payments ], before[:baseline]
      assert_includes before[:drift], @ada.id

      %w[UTC America/Los_Angeles].each do |zone|
        @tenant.update!(time_zone: zone)

        assert_equal before, reads(plan_id), "the cut-off moved when the zone became #{zone}"
      end
    end

    should "hold an archived plan to the instant its archive day ended in Sydney" do
      travel_to Time.utc(2026, 11, 2, 1)
      plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-12-01")[:plan_id]
      travel_to Time.utc(2026, 11, 10, 1)
      ActsAsTenant.with_tenant(@tenant) { handler.archive_plan(plan_id) }
      # Sydney's 10 November ended at 13:00 UTC, LA's at 08:00 on the 11th.
      learn_move(at: Time.utc(2026, 11, 10, 18))

      travel_to Time.utc(2026, 11, 20, 1)
      before = reads(plan_id)

      assert_equal [ @payments ], before[:baseline]

      @tenant.update!(time_zone: "America/Los_Angeles")

      assert_equal before, reads(plan_id)
    end

    should "end a day recorded before tenants had zones at midnight UTC" do
      travel_to Time.utc(2026, 11, 2, 1)
      plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-11-03")[:plan_id]
      travel_to SYDNEY_9AM_17TH
      old_shape = TeamPlanning::Events::PlanArchived.new(data: { plan_id:, archived_by_id: @editor.person_id })
      ActsAsTenant.with_tenant(@tenant) do
        event_store.with_metadata(tenant_id: @tenant.id) do
          event_store.publish(old_shape, stream_name: EventStreamNaming.plan_stream(plan_id), expected_version: :any)
        end
        TeamPlanningPlan.where(id: plan_id).update_all(base_known_at: nil)
      end

      row = plan(plan_id)

      assert_equal Time.utc(2026, 11, 2).end_of_day, row.base_known_at
      assert_equal Time.utc(2026, 11, 16).end_of_day, row.archived_known_at
    end

    should "replay a plan created and updated before tenants had zones to UTC day ends" do
      plan_id = SecureRandom.uuid_v7
      created = TeamPlanning::Events::PlanCreated.new(data: { plan_id:, name: "Next year", base_on: "2026-11-03",
                                                              created_by_id: @editor.person_id })
      rebased = TeamPlanning::Events::PlanRebased.new(data: { plan_id:, base_on: "2026-11-10", previous_base_on: "2026-11-03",
                                                              conflicts: [], rebased_by_id: @editor.person_id })
      publish(plan_id, created)
      @tenant.update!(time_zone: "America/Los_Angeles")
      replay(plan_id)

      assert_equal Time.utc(2026, 11, 2).end_of_day, plan(plan_id).base_known_at

      publish(plan_id, rebased)
      replay(plan_id)
      row = plan(plan_id)

      assert_nil row.read_attribute(:base_known_at)
      assert_equal Time.utc(2026, 11, 9).end_of_day, row.base_known_at
    end
  end

  private

  def org = OrgGraph::CommandHandler.new(actor: SYSTEM)

  def handler = TeamPlanning::CommandHandler.new(actor: context)

  def learn_move(at:)
    travel_to(at) do
      ActsAsTenant.with_tenant(@tenant) do
        org.move_membership(@ada.id, @payments, @platform, effective_on: "2026-10-15")
      end
    end
  end

  # What a reader sees of the archived plan: where its baseline puts Ada,
  # who drifted, each change's status, and the plan's cost.
  def reads(plan_id)
    ActsAsTenant.with_tenant(@tenant) do
      row = plan(plan_id)
      baseline = TeamPlanning::Baseline.new(context:, plan: row).structure
      { baseline: baseline.people.find { it.id == @ada.id }.memberships.map(&:unit_id),
        drift: TeamPlanning::Drift.new(context:, plan: row).call.changes.map { it.change.person_id },
        status: TeamPlanning::Status.new(context:, plan: row, scenario_id: plan_id).call.statuses.map(&:to_h),
        cost: TeamPlanning::Cost.new(context:, plan: row, scenario_id: plan_id).call.to_h.except(:bands_changed_at) }
    end
  end

  def event_store = Rails.configuration.event_store

  def publish(plan_id, event)
    ActsAsTenant.with_tenant(@tenant) do
      event_store.with_metadata(tenant_id: @tenant.id) do
        event_store.publish(event, stream_name: EventStreamNaming.plan_stream(plan_id), expected_version: :any)
      end
    end
  end

  def replay(plan_id)
    projection = TeamPlanning::Projections::Plans.new
    ActsAsTenant.with_tenant(@tenant) do
      event_store.read.stream(EventStreamNaming.plan_stream(plan_id)).each { projection.call(it) }
    end
  end
end
