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
      squads = SecureRandom.uuid_v7
      structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
      structure.define_taxonomy([ { level_id: squads, name: "Squad" } ], effective_on: "2026-10-01")
      structure.create_unit(SecureRandom.uuid_v7, "Payments", level_id: squads, effective_on: "2026-10-01")
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

  private

  def event_store = Rails.configuration.event_store

  def replay(plan_id)
    projection = TeamPlanning::Projections::Plans.new
    ActsAsTenant.with_tenant(@tenant) do
      event_store.read.stream(EventStreamNaming.plan_stream(plan_id)).each { projection.call(it) }
    end
  end
end
