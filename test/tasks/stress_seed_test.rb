# frozen_string_literal: true

require "test_helper"
require "rake"
require Rails.root.join("lib/tasks/stress_seed")

class StressSeedTest < ActiveSupport::TestCase
  def run_seed
    StressSeed.new(people: 30, rated: 8, io: StringIO.new).call
  end

  def snapshot(tenant)
    events = ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql(
      [ "SELECT count(*) FROM event_store_events_in_streams WHERE stream LIKE ?", "tenant-#{tenant.id}/%" ]
    ))
    ActsAsTenant.with_tenant(tenant) do
      [ Person, TenantUser, FrameworkState::Framework, FrameworkState::SuggestedEdit, AssessmentCycle,
        AssessmentCycleEnrollment, AssessmentLevelRating.across_all_roles, EvidenceItem,
        PersonDevelopmentComment, EvidenceRequest, CalibrationSession ]
        .index_by(&:name).transform_values(&:count).merge("events" => events)
    end
  end

  should "leave the same data when run twice" do
    tenant = run_seed
    first = snapshot(tenant)
    run_seed

    assert_operator first["events"], :>, 0
    assert_equal first, snapshot(tenant)
  end

  should "refuse to run in production" do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["dev:seed:stress"].reenable

    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production")) do
      assert_raises(SystemExit) { capture_io { Rake::Task["dev:seed:stress"].invoke } }
    end
    assert_not Tenant.exists?(slug: StressSeed::SLUG)
  end
end
