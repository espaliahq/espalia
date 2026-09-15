# frozen_string_literal: true

require "test_helper"
require "rake"

# The predeploy hook's rebuild (events:projections:rebuild_if_stale): a
# projection already stamped at its CODE_VERSION must be left alone — a
# rebuild truncates live tables while the previous release still serves —
# while a stale stamp still gets the full reset-and-replay.
class ProjectionsRebuildIfStaleTaskTest < ActiveSupport::TestCase
  PROJECTION = PersonDevelopment::Projections::CurrentAssessment

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    %w[events:projections:rebuild_if_stale events:projections:rebuild].each { |t| Rake::Task[t].reenable }

    @tenant = create(:tenant)
    # A read-model row no event backs: a real rebuild's reset! wipes it and
    # nothing replays it, so its survival tells the two paths apart.
    @marker = ActsAsTenant.with_tenant(@tenant) { create(:person_framework_assignment, tenant: @tenant) }
  end

  def run_task
    out, = capture_io { Rake::Task["events:projections:rebuild_if_stale"].invoke(PROJECTION::PROJECTION_NAME) }
    out
  end

  def marker_exists?
    ActsAsTenant.with_tenant(@tenant) { PersonFrameworkAssignment.exists?(@marker.id) }
  end

  should "skip the rebuild when the projection is already at its CODE_VERSION" do
    ProjectionVersion.stamp!(PROJECTION)

    out = run_task

    assert_match(/already at CODE_VERSION #{PROJECTION::CODE_VERSION}/, out)
    assert marker_exists?, "live rows must not be truncated"
  end

  should "rebuild and restamp when the stamp is behind" do
    ProjectionVersion.upsert(
      { name: PROJECTION::PROJECTION_NAME, version: PROJECTION::CODE_VERSION - 1, applied_at: 1.day.ago },
      unique_by: :name
    )

    out = run_task

    assert_match(/rebuilding/, out)
    assert_not marker_exists?, "a real rebuild resets the table"
    assert_equal PROJECTION::CODE_VERSION, ProjectionVersion.find(PROJECTION::PROJECTION_NAME).version
  end

  should "rebuild a projection that was never stamped" do
    ProjectionVersion.where(name: PROJECTION::PROJECTION_NAME).delete_all

    out = run_task

    assert_match(/never rebuilt/, out)
    assert_not marker_exists?
  end
end

# Path B's stamp promotion: after an out-of-band rebuild on the shipped handler
# code, the stamp is moved to the version the bump PR will declare, so its
# predeploy verifies without a second rebuild.
class ProjectionsMarkRebuiltTaskTest < ActiveSupport::TestCase
  PROJECTION = PersonDevelopment::Projections::CurrentAssessment

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["events:projections:mark_rebuilt"].reenable
  end

  def mark(*args)
    out, = capture_io { Rake::Task["events:projections:mark_rebuilt"].invoke(*args) }
    Rake::Task["events:projections:mark_rebuilt"].reenable
    out
  end

  should "stamp the current CODE_VERSION when no version is given" do
    mark(PROJECTION::PROJECTION_NAME)
    assert_equal PROJECTION::CODE_VERSION, ProjectionVersion.find(PROJECTION::PROJECTION_NAME).version
  end

  should "promote the stamp to an explicit later version" do
    ProjectionVersion.stamp!(PROJECTION)
    target = PROJECTION::CODE_VERSION + 1

    out = mark(PROJECTION::PROJECTION_NAME, target.to_s)

    assert_match(/version #{target}/, out)
    assert_equal target, ProjectionVersion.find(PROJECTION::PROJECTION_NAME).version
  end

  should "refuse to move a stamp backwards" do
    ProjectionVersion.stamp!(PROJECTION)

    assert_raises(SystemExit) { mark(PROJECTION::PROJECTION_NAME, (PROJECTION::CODE_VERSION - 1).to_s) }
    assert_equal PROJECTION::CODE_VERSION, ProjectionVersion.find(PROJECTION::PROJECTION_NAME).version
  end
end
