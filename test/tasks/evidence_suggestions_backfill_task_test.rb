# frozen_string_literal: true

require "test_helper"
require "rake"
require_relative "../support/placement_suggestion_fixture"

# evidence:suggestions:backfill_self — a dry run unless CONFIRM=1.
class EvidenceSuggestionsBackfillTaskTest < ActiveJob::TestCase
  include PlacementSuggestionFixture

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["evidence:suggestions:backfill_self"].reenable
    build_placement_fixture
    @item = record_self_feedback
    clear_enqueued_jobs
  end

  teardown do
    ActsAsTenant.current_tenant = nil
    ENV.delete("CONFIRM")
  end

  def run_task
    Evidence::SuggestionModel.stub(:configured?, true) do
      capture_io { Rake::Task["evidence:suggestions:backfill_self"].invoke }.first
    end
  end

  should "count what it would ask for and enqueue nothing by default" do
    output = run_task

    assert_includes output, "#{@tenant.slug}: 1"
    assert_includes output, "Dry run: 1 self feedback items would get suggestions"
    assert_includes output, "CONFIRM=1"
    assert_no_enqueued_jobs(only: Evidence::SuggestPlacementsJob)
  end

  should "enqueue one run per item with CONFIRM=1" do
    ENV["CONFIRM"] = "1"
    output = run_task

    assert_includes output, "Enqueued 1 suggestion runs"
    assert_enqueued_with(job: Evidence::SuggestPlacementsJob, args: [ @item.id ])
  end
end
