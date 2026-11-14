# frozen_string_literal: true

require "test_helper"
require "rake"

# The operator tasks around TeamPlanning::NameSealing print counts, never a name.
class TeamPlanningNamesTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    %w[team_planning:names:dry_run team_planning:names:seal].each { Rake::Task[it].reenable }
    @tenant = create(:tenant)
    TeamPlanning::NameSealing::StoredEvent.create!(
      event_id: SecureRandom.uuid, event_type: "TeamPlanning::Events::PlanCreated", created_at: Time.current,
      data: JSON.generate("plan_id" => SecureRandom.uuid_v7, "name" => "Next year", "base_on" => "2026-11-14",
                          "created_by_id" => SecureRandom.uuid_v7),
      metadata: JSON.generate("tenant_id" => @tenant.id, "types" => {
        "data" => %w[plan_id name base_on created_by_id].to_h { [ it, %w[Symbol String] ] },
        "metadata" => { "tenant_id" => %w[Symbol String] }
      })
    )
  end

  should "count in a dry run, seal on request, and print no name" do
    dry_run = capture_io { Rake::Task["team_planning:names:dry_run"].invoke }.first
    sealed = capture_io { Rake::Task["team_planning:names:seal"].invoke }.first

    assert_includes dry_run, "[#{@tenant.id}] would seal 1: PlanCreated 1, PlanRenamed 0, ScenarioForked 0"
    assert_includes sealed, "[#{@tenant.id}] sealed 1: PlanCreated 1, PlanRenamed 0, ScenarioForked 0"
    assert_not_includes dry_run + sealed, "Next year"
    assert_equal 0, TeamPlanning::NameSealing.new(@tenant).dry_run.values.sum
  end
end
