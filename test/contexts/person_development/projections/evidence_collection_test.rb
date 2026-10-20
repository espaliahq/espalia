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
      cycle_id = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: evidence_id,
        capability_stable_id: cap_sid,
        level_ordinal: 3,
        source: "manager",
        feedback_direction: "manager_to_report",
        evidence_type: "code_review",
        custom_type_label: nil,
        title: "Reviewed PR",
        content: "Strong testing approach",
        external_reference: { system: "github", url: "https://github.com/o/r/pull/1" },
        author_id: @author.id,
        cycle_id: cycle_id)

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(evidence_id)
        assert_equal @person_id, item.person_id
        assert_equal @framework_id, item.framework_id
        assert_equal cycle_id, item.cycle_id
        assert_equal cap_sid, item.capability_stable_id
        assert_equal 3, item.level_ordinal
        assert_equal "manager", item.source
        assert_equal "manager_to_report", item.feedback_direction
        assert_equal "code_review", item.evidence_type
        assert_equal "Reviewed PR", item.title
        assert_equal "Strong testing approach", item.content
        assert_equal "github", item.external_reference.system
        assert_equal @author.id, item.author_id
        assert_equal "active", item.link_status
        assert_not_nil item.recorded_at

        assert_not item.recorded_unplaced
        # The first link is materialised alongside the content row.
        link = EvidenceLink.find_by(evidence_id: evidence_id)
        assert_equal cap_sid, link.capability_stable_id
        assert_equal 3, link.level_ordinal
        assert_equal "active", link.link_status
        assert_equal @author.id, link.linked_by_id
        assert_equal @person_id, link.person_id
        assert_equal @framework_id, link.framework_id
      end
    end

    should "record the surface it came through, and leave it nil on history" do
      slack_id = SecureRandom.uuid_v7
      history_id = SecureRandom.uuid_v7
      attrs = { capability_stable_id: nil, level_ordinal: nil, valence: nil, source: "peer",
                feedback_direction: "peer_to_peer", evidence_type: "peer_feedback", custom_type_label: nil,
                title: nil, content: "Thanks", external_reference: nil, author_id: @author.id }

      emit(PersonDevelopment::Events::EvidenceRecorded, evidence_id: slack_id, acting_via: "slack", **attrs)
      emit(PersonDevelopment::Events::EvidenceRecorded, evidence_id: history_id, **attrs)

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "slack", EvidenceItem.find(slack_id).recorded_via
        assert_nil EvidenceItem.find(history_id).recorded_via
      end
    end

    should "create an unplaced item with no link row when the event carries no cell" do
      evidence_id = SecureRandom.uuid_v7
      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: evidence_id, capability_stable_id: nil, level_ordinal: nil, valence: nil,
        source: "peer", feedback_direction: "peer_to_peer", evidence_type: "peer_feedback",
        custom_type_label: nil, title: nil, content: "Great incident call",
        external_reference: nil, author_id: @author.id)

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(evidence_id)
        assert_nil item.capability_stable_id
        assert_nil item.level_ordinal
        assert_equal "active", item.link_status
        assert_equal 0, EvidenceLink.where(evidence_id: evidence_id).count
        assert_includes EvidenceItem.unplaced, item
        assert item.unplaced?
      end

      ActsAsTenant.with_tenant(@tenant) { EvidenceItem.where(id: evidence_id).update_all(updated_at: 1.day.ago) }

      # The first placement becomes the origin, so origin-anchored readers see it.
      emit(PersonDevelopment::Events::EvidenceLinkAdded,
        evidence_id: evidence_id, capability_stable_id: "0190f4b2-0000-7000-8000-000000000001",
        level_ordinal: 4, linked_by_id: @author.id, valence: "demonstrated")
      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(evidence_id)
        assert_equal "0190f4b2-0000-7000-8000-000000000001", item.capability_stable_id
        assert_equal 4, item.level_ordinal
        assert item.recorded_unplaced, "the fact that someone else chose the cell survives placement"
        assert_not item.unplaced?
        assert_not_includes EvidenceItem.unplaced, item
      end

      ActsAsTenant.with_tenant(@tenant) do
        assert_operator EvidenceItem.find(evidence_id).updated_at, :>, 1.minute.ago
      end

      # Re-applying the origin-less EvidenceRecorded (an at-least-once replay)
      # must not take the adopted origin away again.
      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: evidence_id, capability_stable_id: nil, level_ordinal: nil, valence: nil,
        source: "peer", feedback_direction: "peer_to_peer", evidence_type: "peer_feedback",
        custom_type_label: nil, title: nil, content: "Great incident call",
        external_reference: nil, author_id: @author.id)
      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "0190f4b2-0000-7000-8000-000000000001", EvidenceItem.find(evidence_id).capability_stable_id
      end
    end

    should "store the origin link's valence, and leave it nil for pre-valence events" do
      with_valence = SecureRandom.uuid_v7
      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: with_valence, capability_stable_id: SecureRandom.uuid_v7,
        level_ordinal: 2, source: "self", evidence_type: "project_outcome",
        custom_type_label: nil, title: nil, content: "x",
        external_reference: nil, author_id: @author.id, valence: "growth_area")

      # Historical shape — no :valence key at all.
      pre_valence = SecureRandom.uuid_v7
      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: pre_valence, capability_stable_id: SecureRandom.uuid_v7,
        level_ordinal: 2, source: "self", evidence_type: "project_outcome",
        custom_type_label: nil, title: nil, content: "y",
        external_reference: nil, author_id: @author.id)

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "growth_area", EvidenceLink.find_by(evidence_id: with_valence).valence
        assert_nil EvidenceItem.find(pre_valence).cycle_id
        assert_nil EvidenceItem.find(pre_valence).feedback_direction
        assert_nil EvidenceLink.find_by(evidence_id: pre_valence).valence
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

  context "EvidenceLinkAdded" do
    should "create an additional active link without touching the item content" do
      evidence_id = SecureRandom.uuid_v7
      cap_sid = SecureRandom.uuid_v7
      cap_sid2 = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: evidence_id, capability_stable_id: cap_sid, level_ordinal: 2,
        source: "self", evidence_type: "project_outcome", custom_type_label: nil,
        title: nil, content: "x", external_reference: nil, author_id: @author.id)

      emit(PersonDevelopment::Events::EvidenceLinkAdded,
        evidence_id: evidence_id, capability_stable_id: cap_sid2, level_ordinal: 4,
        linked_by_id: @author.id, rationale: "Also applies")

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(evidence_id)
        # Origin columns unchanged.
        assert_equal cap_sid, item.capability_stable_id
        assert_equal 2, item.level_ordinal

        links = EvidenceLink.active.where(evidence_id: evidence_id).order(:linked_at)
        assert_equal [ [ cap_sid, 2 ], [ cap_sid2, 4 ] ],
          links.pluck(:capability_stable_id, :level_ordinal)
      end
    end

    should "be idempotent on replay (re-applying leaves one active row)" do
      evidence_id = SecureRandom.uuid_v7
      cap_sid = SecureRandom.uuid_v7
      cap_sid2 = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: evidence_id, capability_stable_id: cap_sid, level_ordinal: 2,
        source: "self", evidence_type: "project_outcome", custom_type_label: nil,
        title: nil, content: "x", external_reference: nil, author_id: @author.id)

      2.times do
        emit(PersonDevelopment::Events::EvidenceLinkAdded,
          evidence_id: evidence_id, capability_stable_id: cap_sid2, level_ordinal: 4,
          linked_by_id: @author.id, rationale: nil)
      end

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal 1, EvidenceLink.where(evidence_id: evidence_id,
                                           capability_stable_id: cap_sid2, level_ordinal: 4).count
      end
    end
  end

  context "EvidenceLinkRevalenced" do
    should "update the link's valence in place" do
      evidence_id = SecureRandom.uuid_v7
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: evidence_id, capability_stable_id: cap_sid, level_ordinal: 2,
        source: "self", evidence_type: "project_outcome", custom_type_label: nil,
        title: nil, content: "x", external_reference: nil, author_id: @author.id,
        valence: "demonstrated")

      emit(PersonDevelopment::Events::EvidenceLinkRevalenced,
        evidence_id: evidence_id, capability_stable_id: cap_sid, level_ordinal: 2,
        previous_valence: "demonstrated", valence: "significant_growth_area",
        changed_by_id: @author.id)

      ActsAsTenant.with_tenant(@tenant) do
        link = EvidenceLink.find_by(evidence_id: evidence_id)
        assert_equal "significant_growth_area", link.valence
        assert_equal "active", link.link_status
      end
    end

    should "be a no-op when the link row is missing" do
      emit(PersonDevelopment::Events::EvidenceLinkRevalenced,
        evidence_id: SecureRandom.uuid_v7, capability_stable_id: SecureRandom.uuid_v7,
        level_ordinal: 2, previous_valence: nil, valence: "demonstrated",
        changed_by_id: @author.id)

      ActsAsTenant.with_tenant(@tenant) { assert_equal 0, EvidenceLink.count }
    end
  end

  context "EvidenceLinkRemoved" do
    should "soft-remove the link and leave the item active" do
      evidence_id = SecureRandom.uuid_v7
      cap_sid = SecureRandom.uuid_v7
      cap_sid2 = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: evidence_id, capability_stable_id: cap_sid, level_ordinal: 2,
        source: "self", evidence_type: "project_outcome", custom_type_label: nil,
        title: nil, content: "x", external_reference: nil, author_id: @author.id)
      emit(PersonDevelopment::Events::EvidenceLinkAdded,
        evidence_id: evidence_id, capability_stable_id: cap_sid2, level_ordinal: 4,
        linked_by_id: @author.id, rationale: nil)

      emit(PersonDevelopment::Events::EvidenceLinkRemoved,
        evidence_id: evidence_id, capability_stable_id: cap_sid, level_ordinal: 2,
        removed_by_id: @author.id, reason: "Mislinked")

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "active", EvidenceItem.find(evidence_id).link_status
        removed = EvidenceLink.find_by(evidence_id: evidence_id,
                                       capability_stable_id: cap_sid, level_ordinal: 2)
        assert_equal "removed", removed.link_status
        assert_equal @author.id, removed.removed_by_id
        assert_equal "Mislinked", removed.removal_reason
        assert_equal [ [ cap_sid2, 4 ] ],
          EvidenceLink.active.where(evidence_id: evidence_id).pluck(:capability_stable_id, :level_ordinal)
      end
    end

    should "be a no-op when the link row is missing" do
      assert_nothing_raised do
        emit(PersonDevelopment::Events::EvidenceLinkRemoved,
          evidence_id: SecureRandom.uuid_v7, capability_stable_id: SecureRandom.uuid_v7,
          level_ordinal: 1, removed_by_id: @author.id, reason: nil)
      end
    end
  end

  context "EvidenceRelinked (historical replay)" do
    should "remove the previous link, add the new one, and move the origin columns" do
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

        assert_equal "removed",
          EvidenceLink.find_by(evidence_id: evidence_id, capability_stable_id: cap_sid).link_status
        assert_equal [ [ new_cap_sid, 4 ] ],
          EvidenceLink.active.where(evidence_id: evidence_id).pluck(:capability_stable_id, :level_ordinal)
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

  context "FrameworkVersionMigrated" do
    setup do
      @from_stable_id = SecureRandom.uuid_v7
      @to_stable_id   = SecureRandom.uuid_v7
      @ev_id = SecureRandom.uuid_v7
      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: @ev_id, capability_stable_id: @from_stable_id, level_ordinal: 3,
        source: "self", evidence_type: "project_outcome", custom_type_label: nil,
        title: "Before migration", content: "x", external_reference: nil,
        author_id: @author.id)
    end

    should "move the item's feed position when a mapping re-keys its cell" do
      ActsAsTenant.with_tenant(@tenant) { EvidenceItem.where(id: @ev_id).update_all(updated_at: 1.day.ago) }

      emit(PersonDevelopment::Events::FrameworkVersionMigrated,
        framework_id: @framework_id, old_version: 1, new_version: 2,
        mappings: [ { from_stable_id: @from_stable_id, to_stable_id: @to_stable_id,
                      mapping_type: "evolved", requires_reassessment: false } ])

      ActsAsTenant.with_tenant(@tenant) { assert_operator EvidenceItem.find(@ev_id).updated_at, :>, 1.hour.ago }
    end

    should "re-key evidence rows and links for a same mapping" do
      emit(PersonDevelopment::Events::FrameworkVersionMigrated,
        framework_id: @framework_id, old_version: 1, new_version: 2,
        mappings: [ { from_stable_id: @from_stable_id, to_stable_id: @to_stable_id,
                      mapping_type: "same", requires_reassessment: false } ])

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(@ev_id)
        assert_equal @to_stable_id, item.capability_stable_id
        assert_equal "active", item.link_status
        assert_equal [ [ @to_stable_id, 3 ] ],
          EvidenceLink.active.where(evidence_id: @ev_id).pluck(:capability_stable_id, :level_ordinal)
      end
    end

    should "withdraw a single-link item when its only link is archived" do
      emit(PersonDevelopment::Events::FrameworkVersionMigrated,
        framework_id: @framework_id, old_version: 1, new_version: 2,
        mappings: [ { from_stable_id: @from_stable_id, to_stable_id: nil,
                      mapping_type: "archived", requires_reassessment: false } ])

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(@ev_id)
        assert_equal "withdrawn", item.link_status
        assert_equal "framework_migration_orphaned", item.withdrawal_reason
        assert_not_nil item.withdrawn_at
        assert_equal "removed",
          EvidenceLink.find_by(evidence_id: @ev_id, capability_stable_id: @from_stable_id).link_status
      end
    end

    # Regression: `same`/`evolved` onto a survivor the item is ALREADY linked
    # to at the same level. `idx_evidence_links_natural_key` forbids re-keying
    # the retiring link, so it is closed as merged and the survivor link stays.
    should "merge a link into the survivor's existing link instead of duplicating it" do
      emit(PersonDevelopment::Events::EvidenceLinkAdded,
        evidence_id: @ev_id, capability_stable_id: @to_stable_id, level_ordinal: 3,
        linked_by_id: @author.id, rationale: nil)
      # A second item linked only to the retiring capability still re-keys.
      other_id = SecureRandom.uuid_v7
      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: other_id, capability_stable_id: @from_stable_id, level_ordinal: 3,
        source: "self", evidence_type: "project_outcome", custom_type_label: nil,
        title: "Only on retiring", content: "y", external_reference: nil,
        author_id: @author.id)

      assert_nothing_raised do
        emit(PersonDevelopment::Events::FrameworkVersionMigrated,
          framework_id: @framework_id, old_version: 1, new_version: 2,
          mappings: [ { from_stable_id: @from_stable_id, to_stable_id: @to_stable_id,
                        mapping_type: "evolved", requires_reassessment: true } ])
      end

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(@ev_id)
        assert_equal "active", item.link_status, "item keeps its surviving link"
        assert_equal @to_stable_id, item.capability_stable_id

        assert_equal [ [ @to_stable_id, 3 ] ],
          EvidenceLink.active.where(evidence_id: @ev_id).pluck(:capability_stable_id, :level_ordinal)
        merged = EvidenceLink.find_by(evidence_id: @ev_id, capability_stable_id: @from_stable_id)
        assert_equal "removed", merged.link_status
        assert_equal "framework_migration_merged", merged.removal_reason
        assert_not_nil merged.removed_at

        assert_equal [ [ @to_stable_id, 3 ] ],
          EvidenceLink.active.where(evidence_id: other_id).pluck(:capability_stable_id, :level_ordinal),
          "non-colliding link is still re-keyed"
      end
    end

    # The survivor link exists but was REMOVED earlier. The retiring link is the
    # item's only live anchor, so the survivor link is revived rather than the
    # item being withdrawn as orphaned.
    should "revive a removed survivor link instead of orphaning the item" do
      emit(PersonDevelopment::Events::EvidenceLinkAdded,
        evidence_id: @ev_id, capability_stable_id: @to_stable_id, level_ordinal: 3,
        linked_by_id: @author.id, rationale: nil)
      emit(PersonDevelopment::Events::EvidenceLinkRemoved,
        evidence_id: @ev_id, capability_stable_id: @to_stable_id, level_ordinal: 3,
        removed_by_id: @author.id, reason: "oops")

      emit(PersonDevelopment::Events::FrameworkVersionMigrated,
        framework_id: @framework_id, old_version: 1, new_version: 2,
        mappings: [ { from_stable_id: @from_stable_id, to_stable_id: @to_stable_id,
                      mapping_type: "evolved", requires_reassessment: true } ])

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(@ev_id)
        assert_equal "active", item.link_status, "item must not be withdrawn"
        assert_equal @to_stable_id, item.capability_stable_id

        survivor = EvidenceLink.find_by(evidence_id: @ev_id, capability_stable_id: @to_stable_id)
        assert_equal "active", survivor.link_status
        assert_nil survivor.removal_reason
        assert_equal @author.id, survivor.linked_by_id

        retiring = EvidenceLink.find_by(evidence_id: @ev_id, capability_stable_id: @from_stable_id)
        assert_equal "removed", retiring.link_status
        assert_equal "framework_migration_merged", retiring.removal_reason
      end
    end

    should "treat a same mapping (no survivor) and a self-mapping as no-ops" do
      assert_nothing_raised do
        emit(PersonDevelopment::Events::FrameworkVersionMigrated,
          framework_id: @framework_id, old_version: 1, new_version: 2,
          mappings: [ { from_stable_id: @from_stable_id, to_stable_id: nil,
                        mapping_type: "same", requires_reassessment: false },
                      { from_stable_id: @from_stable_id, to_stable_id: @from_stable_id,
                        mapping_type: "evolved", requires_reassessment: true } ])
      end

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(@ev_id)
        assert_equal "active", item.link_status
        assert_equal @from_stable_id, item.capability_stable_id
        assert_equal [ [ @from_stable_id, 3 ] ],
          EvidenceLink.active.where(evidence_id: @ev_id).pluck(:capability_stable_id, :level_ordinal)
      end
    end

    should "keep a multi-link item active when only one of its links is archived" do
      survivor_stable_id = SecureRandom.uuid_v7
      emit(PersonDevelopment::Events::EvidenceLinkAdded,
        evidence_id: @ev_id, capability_stable_id: survivor_stable_id, level_ordinal: 3,
        linked_by_id: @author.id, rationale: nil)

      emit(PersonDevelopment::Events::FrameworkVersionMigrated,
        framework_id: @framework_id, old_version: 1, new_version: 2,
        mappings: [ { from_stable_id: @from_stable_id, to_stable_id: nil,
                      mapping_type: "archived", requires_reassessment: false } ])

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(@ev_id)
        assert_equal "active", item.link_status
        assert_equal [ [ survivor_stable_id, 3 ] ],
          EvidenceLink.active.where(evidence_id: @ev_id).pluck(:capability_stable_id, :level_ordinal)
      end
    end
  end

  context "rebuild contract" do
    should "reset! + replay produces identical read-model state" do
      cap_sid     = SecureRandom.uuid_v7
      new_cap_sid = SecureRandom.uuid_v7
      ev1_id      = SecureRandom.uuid_v7
      ev2_id      = SecureRandom.uuid_v7

      # ev1 carries current valence and direction fields plus a subsequent
      # reclassification; ev2 stays the historical pre-valence/direction shape.
      # The round trip must reproduce both (this is what the "no CODE_VERSION
      # bump needed" claim rests on).
      append_and_project(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: ev1_id, capability_stable_id: cap_sid, level_ordinal: 2,
        source: "self", evidence_type: "project_outcome", custom_type_label: nil,
        title: "Initial", content: "first", external_reference: nil,
        author_id: @author.id, valence: "demonstrated", feedback_direction: "self", acting_via: "web")

      append_and_project(PersonDevelopment::Events::EvidenceLinkRevalenced,
        evidence_id: ev1_id, capability_stable_id: cap_sid, level_ordinal: 2,
        previous_valence: "demonstrated", valence: "growth_area",
        changed_by_id: @author.id)

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

      # ev3 is recorded unplaced and placed afterwards — the one shape that
      # starts with no link row.
      ev3_id = SecureRandom.uuid_v7
      append_and_project(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: ev3_id, capability_stable_id: nil, level_ordinal: nil, valence: nil,
        source: "peer", evidence_type: "peer_feedback", custom_type_label: nil,
        title: nil, content: "unplaced", external_reference: nil,
        author_id: @author.id, feedback_direction: "peer_to_peer")
      append_and_project(PersonDevelopment::Events::EvidenceLinkAdded,
        evidence_id: ev3_id, capability_stable_id: cap_sid, level_ordinal: 2,
        linked_by_id: @author.id, valence: "demonstrated")

      before_snapshot = snapshot_read_models(PersonDevelopment::Projections::EvidenceCollection, @tenant)
      assert_equal 3, before_snapshot[:evidence_items].size

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

  def emit(event_class, acting_via: nil, **data)
    event = event_class.new(
      data: data,
      metadata: {
        tenant_id: @tenant.id,
        person_id: @person_id,
        framework_id: @framework_id,
        acting_via: acting_via
      }.compact
    )
    @projection.call(event)
  end

  # Appends an event to the real store AND calls the projection directly.
  # Uses `append` rather than `publish` so subscribers (especially sync
  # handlers that dispatch domain commands) don't fire and create
  # cascading state we didn't ask for. The projection-under-test still
  # sees the event live via the direct call. Replay later reads the
  # appended events back via `event_store.read.of_type(...)`.
  def append_and_project(event_class, acting_via: nil, **data)
    event = event_class.new(
      data: data,
      metadata: {
        tenant_id: @tenant.id,
        person_id: @person_id,
        framework_id: @framework_id,
        acting_via: acting_via
      }.compact
    )
    stream = EventStreamNaming.person_development_stream(@person_id, @framework_id, tenant: @tenant)
    Rails.configuration.event_store.append(event, stream_name: stream)
    @projection.call(event)
  end
end
