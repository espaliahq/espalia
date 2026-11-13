# frozen_string_literal: true

require "test_helper"
require "rake"

class ProjectionsStampIfNoEventsTaskTest < ActiveSupport::TestCase
  PROJECTION = OrgGraph::Projections::Structure

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["events:projections:stamp_if_no_events"].reenable
    ProjectionVersion.where(name: PROJECTION::PROJECTION_NAME).delete_all
    stamp_others_current
  end

  def run_task
    out, = capture_io { Rake::Task["events:projections:stamp_if_no_events"].invoke }
    out
  end

  def stamp
    ProjectionVersion.find_by(name: PROJECTION::PROJECTION_NAME)&.version
  end

  def stamp_others_current
    (Projections::Registry.classes - [ PROJECTION ]).each { |klass| ProjectionVersion.stamp!(klass) }
  end

  # `append` stores the event without notifying the live projection.
  def append_handled_event
    Rails.configuration.event_store.append(
      OrgGraph::Events::TaxonomyDefined.new(data: { levels: [], previous_levels: [], effective_on: "2026-01-01" }),
      stream_name: "stamp-if-no-events-test"
    )
  end

  should "reset and stamp a never-rebuilt projection whose handled events do not exist yet" do
    tenant = create(:tenant)
    leftover = ActsAsTenant.with_tenant(tenant) do
      OrgTaxonomyLevel.create!(id: SecureRandom.uuid, name: "Leftover", position: 0, effective_on: Date.current)
    end

    out = run_task

    assert_match(/#{Regexp.escape(PROJECTION::PROJECTION_NAME)}: never rebuilt.*stamped/, out)
    assert_equal PROJECTION::CODE_VERSION, stamp
    assert_not ActsAsTenant.with_tenant(tenant) { OrgTaxonomyLevel.exists?(leftover.id) },
      "the stamp must mean what a rebuild means"
  end

  should "leave a projection with history for a real rebuild" do
    append_handled_event

    run_task

    assert_nil stamp
  end

  should "stamp nothing while another never-stamped projection has events to replay" do
    other = PersonDevelopment::Projections::CurrentAssessment
    ProjectionVersion.where(name: other::PROJECTION_NAME).delete_all
    Rails.configuration.event_store.append(other.handled_events.first.new(data: {}), stream_name: "stamp-if-no-events-test")

    out = run_task

    assert_match(/Not stamping new projections: #{Regexp.escape(other::PROJECTION_NAME)}/, out)
    assert_nil stamp
  end

  should "leave a CODE_VERSION bump for an explicit rebuild" do
    ProjectionVersion.promote!(PROJECTION::PROJECTION_NAME, PROJECTION::CODE_VERSION - 1)

    run_task

    assert_equal PROJECTION::CODE_VERSION - 1, stamp
  end

  should "stamp nothing while another projection is stale" do
    other = PersonDevelopment::Projections::CurrentAssessment
    ProjectionVersion.upsert({ name: other::PROJECTION_NAME, version: other::CODE_VERSION - 1, applied_at: Time.current },
                             unique_by: :name)

    out = run_task

    assert_match(/Not stamping new projections: #{Regexp.escape(other::PROJECTION_NAME)}/, out)
    assert_nil stamp
  end
end
