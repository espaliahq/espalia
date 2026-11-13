# frozen_string_literal: true

require "test_helper"
require "rake"

class ProjectionsStampIfNoEventsTaskTest < ActiveSupport::TestCase
  PROJECTION = OrgGraph::Projections::Structure

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["events:projections:stamp_if_no_events"].reenable
    ProjectionVersion.where(name: PROJECTION::PROJECTION_NAME).delete_all
  end

  def run_task
    out, = capture_io { Rake::Task["events:projections:stamp_if_no_events"].invoke }
    out
  end

  def stamp
    ProjectionVersion.find_by(name: PROJECTION::PROJECTION_NAME)&.version
  end

  # `append` stores the event without notifying the live projection.
  def append_handled_event
    Rails.configuration.event_store.append(
      OrgGraph::Events::TaxonomyDefined.new(data: { levels: [], previous_levels: [], effective_on: "2026-01-01" }),
      stream_name: "stamp-if-no-events-test"
    )
  end

  should "stamp a never-rebuilt projection whose handled events do not exist yet" do
    out = run_task

    assert_match(%r{#{PROJECTION::PROJECTION_NAME}: applied=\(never rebuilt\).*stamped}, out)
    assert_equal PROJECTION::CODE_VERSION, stamp
  end

  should "stamp a projection behind CODE_VERSION when it has no events" do
    ProjectionVersion.promote!(PROJECTION::PROJECTION_NAME, PROJECTION::CODE_VERSION - 1)

    run_task

    assert_equal PROJECTION::CODE_VERSION, stamp
  end

  should "leave a projection with history for a real rebuild" do
    append_handled_event

    out = run_task

    assert_no_match(/#{Regexp.escape(PROJECTION::PROJECTION_NAME)}/, out)
    assert_nil stamp
  end

  should "leave a current or promoted stamp alone" do
    ProjectionVersion.promote!(PROJECTION::PROJECTION_NAME, PROJECTION::CODE_VERSION + 1)

    out = run_task

    assert_no_match(/#{Regexp.escape(PROJECTION::PROJECTION_NAME)}/, out)
    assert_equal PROJECTION::CODE_VERSION + 1, stamp
  end
end
