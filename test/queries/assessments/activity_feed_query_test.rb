# frozen_string_literal: true

require "test_helper"

class Assessments::ActivityFeedQueryTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @framework_id = SecureRandom.uuid_v7
    @role_id = SecureRandom.uuid_v7
    @level_id = SecureRandom.uuid_v7
    @cap_sid = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(@tenant) do
      @assessee = create(:person, tenant: @tenant, name: "Assessee")
      @manager = create(:person, tenant: @tenant, name: "Dana Lee")
      @peer = create(:person, tenant: @tenant, name: "Peer")
      @assessee.update!(manager: @manager)

      @assignment = create(:person_framework_assignment,
        tenant: @tenant, person_id: @assessee.id, framework_id: @framework_id,
        role_id: @role_id, level_id: @level_id)

      handler = PersonDevelopment::CommandHandler.new
      cycle_handler = AssessmentCycles::CommandHandler.new
      handler.assign_to_framework(@assessee.id, @framework_id, @role_id, @level_id)
      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, @framework_id, "Q1", "regular", 1,
        defined_by: @assessee.id)
      cycle_handler.enroll(@cycle_id, @assessee.id, enrolled_by: @assessee.id)

      handler.rate_self(@assessee.id, @framework_id, @cap_sid,
        level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id, comment: "Self note")
      handler.rate_as_manager(@assessee.id, @framework_id, @cap_sid,
        level_ordinal: 2, frequency: "occasional", cycle_id: @cycle_id, comment: "Mgr note",
        rated_by_id: @manager.id)

      @evidence_id = SecureRandom.uuid_v7
      handler.record_evidence(@assessee.id, @framework_id, @evidence_id,
        capability_stable_id: @cap_sid, level_ordinal: 2, source: "self",
        evidence_type: "project_outcome", content: "Shipped X.", author_id: @assessee.id,
        title: "Launch")
    end
  end

  context "as the assessee (viewer_sees_all, alignment not started)" do
    setup do
      @entries = run_query(viewer: @assessee, sees_all: true, context: :self,
        alignment_started: false)
    end

    should "include the self-rating event" do
      assert_includes @entries.map(&:kind), "self_rated"
    end

    should "include the evidence event" do
      assert_includes @entries.map(&:kind), "evidence_recorded"
    end

    should "hide the manager-rating event until alignment starts" do
      refute_includes @entries.map(&:kind), "manager_rated"
    end

    should "be reverse-chronological" do
      timestamps = @entries.map(&:occurred_at).compact
      assert_equal timestamps.sort.reverse, timestamps
    end
  end

  context "as the assessee, alignment in progress" do
    setup do
      @entries = run_query(viewer: @assessee, sees_all: true, context: :self,
        alignment_started: true)
    end

    should "now include the manager-rating event" do
      assert_includes @entries.map(&:kind), "manager_rated"
    end
  end

  context "as the manager (sees_all, manager context)" do
    setup do
      @entries = run_query(viewer: @manager, sees_all: true, context: :manager,
        alignment_started: false)
    end

    should "include both rating perspectives" do
      kinds = @entries.map(&:kind)
      assert_includes kinds, "self_rated"
      assert_includes kinds, "manager_rated"
      assert_includes kinds, "evidence_recorded"
    end

    should "resolve the rating manager's name into the entry payload" do
      entry = @entries.find { |e| e.kind == "manager_rated" }
      assert_equal "Dana Lee", entry.payload[:rated_by_name],
        "expected the query to resolve rated_by_id to the rater's name"
    end
  end

  context "as a peer (sees_all = false)" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @peer_evidence_id = SecureRandom.uuid_v7
        PersonDevelopment::CommandHandler.new.record_evidence(
          @assessee.id, @framework_id, @peer_evidence_id,
          capability_stable_id: @cap_sid, level_ordinal: 1, source: "peer",
          evidence_type: "peer_feedback", content: "Strong collaborator",
          author_id: @peer.id
        )
      end
      @entries = run_query(viewer: @peer, sees_all: false, context: :manager,
        alignment_started: false)
    end

    should "hide manager rating events entirely" do
      refute_includes @entries.map(&:kind), "manager_rated"
    end

    should "show only the peer's own evidence" do
      evidence_entries = @entries.select { |e| e.kind == "evidence_recorded" }
      assert_equal 1, evidence_entries.size
      assert_equal "peer_feedback", evidence_entries.first.payload.evidence_type
    end
  end

  context "relinked evidence" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @new_cap_stable = SecureRandom.uuid_v7
        PersonDevelopment::CommandHandler.new.relink_evidence(
          @assessee.id, @framework_id, @evidence_id,
          new_capability_stable_id: @new_cap_stable,
          new_level_ordinal: 4,
          relinked_by_id: @assessee.id,
          rationale: "Better fit at L4"
        )
      end
      @entries = run_query(viewer: @assessee, sees_all: true, context: :self,
        alignment_started: true)
    end

    should "include an evidence_relinked entry on top of the original recorded entry" do
      kinds = @entries.map(&:kind)
      assert_includes kinds, "evidence_recorded"
      assert_includes kinds, "evidence_relinked"
    end

    should "anchor the relink entry to the new (capability, level) coord" do
      relink = @entries.find { |e| e.kind == "evidence_relinked" }
      assert_equal @new_cap_stable, relink.capability_stable_id
      assert_equal 4, relink.level_ordinal
    end

    should "carry the previous coords + rationale on the payload" do
      relink = @entries.find { |e| e.kind == "evidence_relinked" }
      assert_equal @cap_sid, relink.payload[:previous_capability_stable_id]
      assert_equal 2, relink.payload[:previous_level_ordinal]
      assert_equal "Better fit at L4", relink.payload[:rationale]
    end
  end

  context "framework version migration" do
    setup do
      # Inject a FrameworkVersionMigrated event on the assessee's PD stream
      # — two mappings, one survivor + one archived.
      survivor_stable_id = SecureRandom.uuid_v7
      orphan_stable_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        # The activity feed query looks up capability names via the
        # FrameworkState read model — seed both stable_ids so the entries
        # render with names.
        cat = create(:framework_capability_category, framework_id: @framework_id, name: "Eng")
        create(:framework_capability, category_id: cat.category_id,
          stable_id: survivor_stable_id, name: "Survivor")
        create(:framework_capability, category_id: cat.category_id,
          stable_id: orphan_stable_id, name: "Old Cap", status: "archived")
      end

      event = PersonDevelopment::Events::FrameworkVersionMigrated.new(
        data: {
          framework_id: @framework_id, old_version: 1, new_version: 2,
          mappings: [
            { from_stable_id: SecureRandom.uuid_v7, to_stable_id: survivor_stable_id,
              mapping_type: "same", requires_reassessment: false,
              from_capability_name: "Old Survivor Sibling", to_capability_name: "Survivor",
              counts: { ratings: 1, evidence: 0, comments: 0 } },
            { from_stable_id: orphan_stable_id, to_stable_id: nil,
              mapping_type: "archived", requires_reassessment: false,
              from_capability_name: "Old Cap", to_capability_name: nil,
              counts: { ratings: 1, evidence: 0, comments: 0 } }
          ]
        },
        metadata: { tenant_id: @tenant.id, person_id: @assessee.id, framework_id: @framework_id }
      )
      ActsAsTenant.with_tenant(@tenant) do
        stream = EventStreamNaming.person_development_stream(@assessee.id, @framework_id)
        Rails.configuration.event_store.append(event, stream_name: stream)
      end

      @survivor_stable_id = survivor_stable_id
      @entries = run_query(viewer: @assessee, sees_all: true, context: :self,
        alignment_started: false)
    end

    should "emit a capability_migrated entry anchored to the survivor stable_id" do
      cap_migrated = @entries.find { |e| e.kind == "capability_migrated" }
      assert_not_nil cap_migrated
      assert_equal @survivor_stable_id, cap_migrated.capability_stable_id
      assert_equal "Survivor", cap_migrated.capability_name
      assert_equal "same", cap_migrated.payload[:mapping_type]
    end

    should "emit a capabilities_orphaned envelope listing archived/split mappings" do
      orphan = @entries.find { |e| e.kind == "capabilities_orphaned" }
      assert_not_nil orphan
      assert_equal 1, orphan.payload[:orphaned].size
      assert_equal "archived", orphan.payload[:orphaned].first[:mapping_type]
    end
  end

  context "withdrawn evidence" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.withdraw_evidence(
          @assessee.id, @framework_id, @evidence_id,
          withdrawn_by_id: @assessee.id, reason: "Wrong fit"
        )
      end
      @entries = run_query(viewer: @assessee, sees_all: true, context: :self,
        alignment_started: true)
    end

    should "include both recorded and withdrawn entries" do
      kinds = @entries.map(&:kind)
      assert_includes kinds, "evidence_recorded"
      assert_includes kinds, "evidence_withdrawn"
    end
  end

  private

  def run_query(viewer:, sees_all:, context:, alignment_started:)
    ActsAsTenant.with_tenant(@tenant) do
      Assessments::ActivityFeedQuery.new(
        assignment: @assignment.reload,
        context: context,
        viewer_person_id: viewer.id,
        viewer_sees_all: sees_all,
        alignment_started: alignment_started
      ).call
    end
  end
end
