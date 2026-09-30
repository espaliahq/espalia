# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

# CurrentAssessment's declared-exploration rows (ADR-22): one per
# `ExplorationStarted`, keyed by the event's id, closed in place, and rebuilt
# identically by a reset! + replay.
class PersonDevelopment::Projections::CurrentAssessmentExplorationTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  setup do
    @tenant = create(:tenant)
    @projection = PersonDevelopment::Projections::CurrentAssessment.new
    @framework_id = SecureRandom.uuid_v7
    @person_id = SecureRandom.uuid_v7
    @manager_id = SecureRandom.uuid_v7
    @pm_role = SecureRandom.uuid_v7
    @pm3 = SecureRandom.uuid_v7

    append_and_project(PersonDevelopment::Events::PersonAssignedToFramework,
      person_id: @person_id, framework_id: @framework_id, role_id: SecureRandom.uuid_v7,
      level_id: SecureRandom.uuid_v7)
  end

  def start(id = SecureRandom.uuid_v7, note: "Worth a look")
    append_and_project(PersonDevelopment::Events::ExplorationStarted,
      exploration_id: id, target_role_id: @pm_role, target_level_id: @pm3, target_level_ordinal: 3,
      started_by_id: @person_id, note: note)
    id
  end

  def exploration(id)
    ActsAsTenant.with_tenant(@tenant) { AssessmentExploration.find(id) }
  end

  should "write an open row keyed by the exploration id" do
    id = start

    row = exploration(id)
    assert_equal "open", row.status
    assert_equal @person_id, row.person_id
    assert_equal @framework_id, row.framework_id
    assert_equal @pm_role, row.target_role_id
    assert_equal @pm3, row.target_level_id
    assert_equal 3, row.target_level_ordinal
    assert_equal @person_id, row.started_by_id
    assert_equal "Worth a look", row.start_note
    assert_not_nil row.started_at
  end

  should "close the row in place with the outcome" do
    id = start
    append_and_project(PersonDevelopment::Events::ExplorationClosed,
      exploration_id: id, closed_by_id: @manager_id, outcome: "not_now", note: "After the launch")

    row = exploration(id)
    assert_equal "closed", row.status
    assert_equal "not_now", row.outcome
    assert_equal @manager_id, row.closed_by_id
    assert_equal "After the launch", row.close_note
    assert_not_nil row.closed_at
  end

  should "rebuild every row identically, ids included" do
    first = start
    append_and_project(PersonDevelopment::Events::ExplorationClosed,
      exploration_id: first, closed_by_id: @manager_id, outcome: "pursue", note: nil)
    start(note: nil)

    before = snapshot_read_models(PersonDevelopment::Projections::CurrentAssessment, @tenant)
    assert_equal 2, before[:explorations].size

    PersonDevelopment::Projections::CurrentAssessment.reset!(tenant: @tenant)
    ActsAsTenant.with_tenant(@tenant) { assert_equal 0, AssessmentExploration.count }
    Projections::Replayer.replay(projection_class: PersonDevelopment::Projections::CurrentAssessment, tenant: @tenant)

    assert_equal before, snapshot_read_models(PersonDevelopment::Projections::CurrentAssessment, @tenant)
  end

  private

  def append_and_project(event_class, **data)
    event = event_class.new(
      data: data,
      metadata: { tenant_id: @tenant.id, person_id: @person_id, framework_id: @framework_id }
    )
    stream = EventStreamNaming.person_development_stream(@person_id, @framework_id, tenant: @tenant)
    Rails.configuration.event_store.append(event, stream_name: stream)
    @projection.call(event)
  end
end
