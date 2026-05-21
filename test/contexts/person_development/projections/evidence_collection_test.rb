# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class PersonDevelopment::Projections::EvidenceCollectionTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  setup do
    @tenant = create(:tenant)
    @projection = PersonDevelopment::Projections::EvidenceCollection.new
    @person_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(@tenant) do
      @author = create(:person, tenant: @tenant, name: "Author")
    end
  end

  context "EvidenceRecorded" do
    should "create an EvidenceItem row" do
      evidence_id = SecureRandom.uuid_v7
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: evidence_id,
        capability_stable_id: cap_sid,
        level_ordinal: 3,
        source: "manager",
        evidence_type: "code_review",
        custom_type_label: nil,
        title: "Reviewed PR",
        content: "Strong testing approach",
        external_reference: { system: "github", url: "https://github.com/o/r/pull/1" },
        author_id: @author.id)

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(evidence_id)
        assert_equal @person_id, item.person_id
        assert_equal @framework_id, item.framework_id
        assert_equal cap_sid, item.capability_stable_id
        assert_equal 3, item.level_ordinal
        assert_equal "manager", item.source
        assert_equal "code_review", item.evidence_type
        assert_equal "Reviewed PR", item.title
        assert_equal "Strong testing approach", item.content
        assert_equal "github", item.external_reference.system
        assert_equal @author.id, item.author_id
        assert_equal "active", item.link_status
        assert_not_nil item.recorded_at
      end
    end

    should "default external_reference to empty when nil" do
      evidence_id = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: evidence_id,
        capability_stable_id: SecureRandom.uuid_v7,
        level_ordinal: 1, source: "self", evidence_type: "project_outcome",
        custom_type_label: nil, title: nil, content: "x",
        external_reference: nil, author_id: @author.id)

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(evidence_id)
        assert_kind_of ExternalReference, item.external_reference
        assert_not item.external_reference.present?
      end
    end
  end

  context "EvidenceRelinked" do
    should "update capability and level on the existing row" do
      evidence_id = SecureRandom.uuid_v7
      cap_sid = SecureRandom.uuid_v7
      new_cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: evidence_id, capability_stable_id: cap_sid, level_ordinal: 2,
        source: "self", evidence_type: "project_outcome", custom_type_label: nil,
        title: nil, content: "x", external_reference: nil, author_id: @author.id)

      emit(PersonDevelopment::Events::EvidenceRelinked,
        evidence_id: evidence_id,
        previous_capability_stable_id: cap_sid, previous_level_ordinal: 2,
        new_capability_stable_id: new_cap_sid, new_level_ordinal: 4,
        relinked_by_id: @author.id, rationale: "Better fit")

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(evidence_id)
        assert_equal new_cap_sid, item.capability_stable_id
        assert_equal 4, item.level_ordinal
        assert_equal "active", item.link_status
      end
    end

    should "be a no-op when the row is missing" do
      assert_nothing_raised do
        emit(PersonDevelopment::Events::EvidenceRelinked,
          evidence_id: SecureRandom.uuid_v7,
          previous_capability_stable_id: SecureRandom.uuid_v7, previous_level_ordinal: 1,
          new_capability_stable_id: SecureRandom.uuid_v7, new_level_ordinal: 2,
          relinked_by_id: @author.id, rationale: nil)
      end
    end
  end

  context "EvidenceWithdrawn" do
    should "flip link_status and stamp withdrawal fields" do
      evidence_id = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: evidence_id, capability_stable_id: SecureRandom.uuid_v7,
        level_ordinal: 1, source: "self", evidence_type: "project_outcome",
        custom_type_label: nil, title: nil, content: "x",
        external_reference: nil, author_id: @author.id)

      emit(PersonDevelopment::Events::EvidenceWithdrawn,
        evidence_id: evidence_id, withdrawn_by_id: @author.id, reason: "Wrong context")

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(evidence_id)
        assert_equal "withdrawn", item.link_status
        assert_equal @author.id, item.withdrawn_by_id
        assert_equal "Wrong context", item.withdrawal_reason
        assert_not_nil item.withdrawn_at
      end
    end
  end

  context "EvidenceUpdated" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @editor = create(:person, tenant: @tenant, name: "Editor")
      end
    end

    should "update content fields and stamp edited_at + edited_by_id" do
      evidence_id = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: evidence_id, capability_stable_id: SecureRandom.uuid_v7,
        level_ordinal: 2, source: "self", evidence_type: "project_outcome",
        custom_type_label: nil, title: "Old", content: "Old content",
        external_reference: nil, author_id: @author.id)

      emit(PersonDevelopment::Events::EvidenceUpdated,
        evidence_id: evidence_id,
        title: "New title",
        content: "Improved content",
        evidence_type: "code_review",
        custom_type_label: nil,
        external_reference: { system: "github", url: "https://github.com/o/r/pull/7" },
        edited_by_id: @editor.id)

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(evidence_id)
        assert_equal "New title", item.title
        assert_equal "Improved content", item.content
        assert_equal "code_review", item.evidence_type
        assert_nil item.custom_type_label
        assert_equal "github", item.external_reference.system
        assert_equal @editor.id, item.edited_by_id
        assert_not_nil item.edited_at
        # Identity invariants stay untouched.
        assert_equal "self", item.source
        assert_equal @author.id, item.author_id
        assert_equal "active", item.link_status
      end
    end

    should "be a no-op when the row is missing" do
      assert_nothing_raised do
        emit(PersonDevelopment::Events::EvidenceUpdated,
          evidence_id: SecureRandom.uuid_v7,
          title: nil, content: "x", evidence_type: "project_outcome",
          custom_type_label: nil, external_reference: nil, edited_by_id: @editor.id)
      end
    end
  end

  context "rebuild contract" do
    should "reset! + replay produces identical read-model state" do
      cap_sid     = SecureRandom.uuid_v7
      new_cap_sid = SecureRandom.uuid_v7
      ev1_id      = SecureRandom.uuid_v7
      ev2_id      = SecureRandom.uuid_v7

      append_and_project(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: ev1_id, capability_stable_id: cap_sid, level_ordinal: 2,
        source: "self", evidence_type: "project_outcome", custom_type_label: nil,
        title: "Initial", content: "first", external_reference: nil,
        author_id: @author.id)

      append_and_project(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: ev2_id, capability_stable_id: cap_sid, level_ordinal: 3,
        source: "manager", evidence_type: "code_review", custom_type_label: nil,
        title: "Second", content: "follow up",
        external_reference: { system: "github", url: "https://github.com/o/r/pull/2" },
        author_id: @author.id)

      append_and_project(PersonDevelopment::Events::EvidenceRelinked,
        evidence_id: ev2_id,
        previous_capability_stable_id: cap_sid, previous_level_ordinal: 3,
        new_capability_stable_id: new_cap_sid, new_level_ordinal: 4,
        relinked_by_id: @author.id, rationale: nil)

      append_and_project(PersonDevelopment::Events::EvidenceUpdated,
        evidence_id: ev2_id,
        title: "Second (edited)", content: "follow up, expanded",
        evidence_type: "design_review", custom_type_label: nil,
        external_reference: { system: "github", url: "https://github.com/o/r/pull/2" },
        edited_by_id: @author.id)

      append_and_project(PersonDevelopment::Events::EvidenceWithdrawn,
        evidence_id: ev1_id, withdrawn_by_id: @author.id, reason: "Test")

      before_snapshot = snapshot_read_models(PersonDevelopment::Projections::EvidenceCollection, @tenant)
      assert_equal 2, before_snapshot[:evidence_items].size

      PersonDevelopment::Projections::EvidenceCollection.reset!(tenant: @tenant)
      ActsAsTenant.with_tenant(@tenant) { assert_equal 0, EvidenceItem.count }

      Projections::Replayer.replay(
        projection_class: PersonDevelopment::Projections::EvidenceCollection,
        tenant: @tenant
      )

      after_snapshot = snapshot_read_models(PersonDevelopment::Projections::EvidenceCollection, @tenant)
      assert_equal before_snapshot, after_snapshot
    end
  end

  private

  def emit(event_class, **data)
    event = event_class.new(
      data: data,
      metadata: {
        tenant_id: @tenant.id,
        person_id: @person_id,
        framework_id: @framework_id
      }
    )
    @projection.call(event)
  end

  # Appends an event to the real store AND calls the projection directly.
  # Uses `append` rather than `publish` so subscribers (especially sync
  # handlers that dispatch domain commands) don't fire and create
  # cascading state we didn't ask for. The projection-under-test still
  # sees the event live via the direct call. Replay later reads the
  # appended events back via `event_store.read.of_type(...)`.
  def append_and_project(event_class, **data)
    event = event_class.new(
      data: data,
      metadata: {
        tenant_id: @tenant.id,
        person_id: @person_id,
        framework_id: @framework_id
      }
    )
    stream = EventStreamNaming.person_development_stream(@person_id, @framework_id, tenant: @tenant)
    Rails.configuration.event_store.append(event, stream_name: stream)
    @projection.call(event)
  end
end
