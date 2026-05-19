require "test_helper"
require_relative "../../support/projection_replay"

class Projections::GlobalReplayerTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  setup do
    @tenant = create(:tenant)
    @framework_id = SecureRandom.uuid_v7
    @person_id = SecureRandom.uuid_v7
    @cycle_id = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(@tenant) do
      @author = create(:person, tenant: @tenant, name: "Author")
    end

    # One instance per projection class — same instances handle every event so
    # any cross-event state stays consistent (mirrors live subscriptions).
    @projections = Projections::Registry.classes.each_with_object({}) do |klass, h|
      h[klass] = klass.new
    end
  end

  context "replay_all" do
    should "reconstructs shared-row state (the case per-projection rebuild requires ordering for)" do
      # Live: events span two aggregates — cycle creates the participant row,
      # PD updates lifecycle columns on it.
      append_to_cycle_stream(AssessmentCycles::Events::CycleDefined,
        cycle_id: @cycle_id, framework_id: @framework_id, framework_version: 1,
        name: "Q1", cycle_type: "regular", defined_by: nil)

      append_to_cycle_stream(AssessmentCycles::Events::PersonEnrolled,
        cycle_id: @cycle_id, person_id: @person_id, framework_id: @framework_id,
        framework_version: 1, enrolled_by: nil)

      append_to_pd_stream(PersonDevelopment::Events::PersonAssignedToFramework,
        role_id: SecureRandom.uuid_v7, level_id: SecureRandom.uuid_v7)

      append_to_pd_stream(PersonDevelopment::Events::JoinedAssessmentCycle,
        cycle_id: @cycle_id, framework_version: 1)

      append_to_pd_stream(PersonDevelopment::Events::SelfRated,
        cycle_id: @cycle_id, capability_stable_id: SecureRandom.uuid_v7,
        level_ordinal: 2, frequency: "consistent", source: "human")

      before = snapshot_all
      assert_equal 1, before["AssessmentCycles::Projections::CurrentState"][:cycles].size
      assert_equal 1, before["AssessmentCycles::Projections::CurrentState"][:enrollments].size
      assert_equal 1, before["PersonDevelopment::Projections::CurrentAssessment"][:assignments].size
      assert_equal 1, before["PersonDevelopment::Projections::CurrentAssessment"][:assessment_level_ratings].size
      assert_equal 1, before["PersonDevelopment::Projections::CurrentAssessment"][:progress].size

      counts = Projections::GlobalReplayer.replay_all(tenant: @tenant)

      after = snapshot_all
      assert_equal before, after
      assert counts.values.sum > 0, "expected at least some events to be applied"
    end

    should "returns per-projection event counts" do
      append_to_pd_stream(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: SecureRandom.uuid_v7, capability_stable_id: SecureRandom.uuid_v7,
        level_ordinal: 2, source: "self", evidence_type: "project_outcome",
        custom_type_label: nil, title: nil, content: "x",
        external_reference: nil, author_id: @author.id)

      counts = Projections::GlobalReplayer.replay_all(tenant: @tenant)

      assert_equal 1, counts[PersonDevelopment::Projections::EvidenceCollection]
      assert_equal 0, counts[Frameworks::Projections::PublishedState]
    end

    should "scoped to tenant — does not touch events from other tenants" do
      other_tenant = create(:tenant)
      other_cycle_id = SecureRandom.uuid_v7
      other_stream = EventStreamNaming.assessment_cycle_stream(other_cycle_id, tenant: other_tenant)
      other_event = AssessmentCycles::Events::CycleDefined.new(
        data: { cycle_id: other_cycle_id, framework_id: SecureRandom.uuid_v7, framework_version: 1,
                name: "Other", cycle_type: "regular", defined_by: nil },
        metadata: { tenant_id: other_tenant.id }
      )
      Rails.configuration.event_store.append(other_event, stream_name: other_stream)

      counts = Projections::GlobalReplayer.replay_all(tenant: @tenant)

      ActsAsTenant.with_tenant(@tenant)       { assert_equal 0, AssessmentCycle.count }
      ActsAsTenant.with_tenant(other_tenant)  { assert_equal 0, AssessmentCycle.count }  # not replayed for other tenant either
      assert_equal 0, counts.values.sum
    end
  end

  private

  def append_to_cycle_stream(event_class, **data)
    stream = EventStreamNaming.assessment_cycle_stream(@cycle_id, tenant: @tenant)
    event = event_class.new(data: data, metadata: { tenant_id: @tenant.id })
    Rails.configuration.event_store.append(event, stream_name: stream)
    dispatch_live(event_class, event)
  end

  def append_to_pd_stream(event_class, **data)
    stream = EventStreamNaming.person_development_stream(@person_id, @framework_id, tenant: @tenant)
    event = event_class.new(
      data: data,
      metadata: { tenant_id: @tenant.id, person_id: @person_id, framework_id: @framework_id }
    )
    Rails.configuration.event_store.append(event, stream_name: stream)
    dispatch_live(event_class, event)
  end

  def dispatch_live(event_class, event)
    @projections.each do |klass, instance|
      instance.call(event) if klass.handled_events.include?(event_class)
    end
  end

  def snapshot_all
    Projections::Registry.classes.each_with_object({}) do |klass, h|
      h[klass.name] = snapshot_read_models(klass, @tenant)
    end
  end
end
