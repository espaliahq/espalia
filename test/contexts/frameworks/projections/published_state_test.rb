# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class Frameworks::Projections::PublishedStateTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  setup do
    @tenant = create(:tenant)
    @projection = Frameworks::Projections::PublishedState.new
    @framework_id = SecureRandom.uuid_v7
    # framework_suggested_edits.author_id/reviewed_by are FKs to people(id) —
    # tests that emit suggestion events need a real Person in the tenant.
    @author_person = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant) }
  end

  context "FrameworkCreated" do
    should "create a FrameworkState::Framework read model" do
      emit(Frameworks::Events::FrameworkCreated, framework_id: @framework_id, name: "Design Growth")

      within_tenant do
        read_model = FrameworkState::Framework.find_by(framework_id: @framework_id)
        assert_not_nil read_model
        assert_equal "Design Growth", read_model.name
        assert_equal @tenant.id, read_model.tenant_id
        assert_equal 0, read_model.current_published_version
        assert_equal false, read_model.draft_in_progress
      end
    end
  end

  context "FrameworkRenamed" do
    should "update the Framework read model's name" do
      emit(Frameworks::Events::FrameworkCreated, framework_id: @framework_id, name: "Design Growth")
      emit(Frameworks::Events::FrameworkRenamed, framework_id: @framework_id, name: "Design Career Path")

      within_tenant do
        assert_equal "Design Career Path", FrameworkState::Framework.find_by(framework_id: @framework_id).name
      end
    end

    should "survive the publish-time rebuild (not skipped, idempotent)" do
      emit(Frameworks::Events::FrameworkCreated, framework_id: @framework_id, name: "Design Growth")
      emit(Frameworks::Events::FrameworkRenamed, framework_id: @framework_id, name: "Design Career Path")

      assert_not @projection.send(:skip_during_rebuild?,
                                  Frameworks::Events::FrameworkRenamed.new(data: { framework_id: @framework_id, name: "x" }))
      # Re-applying the same event is a no-op update, so a replay can't diverge.
      emit(Frameworks::Events::FrameworkRenamed, framework_id: @framework_id, name: "Design Career Path")
      within_tenant do
        assert_equal "Design Career Path", FrameworkState::Framework.find_by(framework_id: @framework_id).name
      end
    end
  end

  context "RoleFamilyAdded" do
    should "create a RoleFamily read model" do
      rfid = SecureRandom.uuid_v7
      emit(Frameworks::Events::RoleFamilyAdded,
        framework_id: @framework_id, role_family_id: rfid,
        name: "Engineering", description: "Tech roles")

      within_tenant do
        rm = FrameworkState::RoleFamily.find_by(role_family_id: rfid)
        assert_not_nil rm
        assert_equal "Engineering", rm.name
        assert_equal "Tech roles", rm.description
        assert_equal @framework_id, rm.framework_id
      end
    end
  end

  context "RoleFamilyUpdated" do
    should "update the RoleFamily read model" do
      rfid = SecureRandom.uuid_v7
      emit(Frameworks::Events::RoleFamilyAdded,
        framework_id: @framework_id, role_family_id: rfid, name: "Eng")
      emit(Frameworks::Events::RoleFamilyUpdated,
        framework_id: @framework_id, role_family_id: rfid, name: "Software Engineering")

      within_tenant do
        rm = FrameworkState::RoleFamily.find_by(role_family_id: rfid)
        assert_equal "Software Engineering", rm.name
      end
    end
  end

  context "RoleAdded" do
    should "create a Role read model" do
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      emit(Frameworks::Events::RoleAdded,
        framework_id: @framework_id, role_id: rid, role_family_id: rfid,
        name: "Software Engineer", code: "E", track: "ic")

      within_tenant do
        rm = FrameworkState::Role.find_by(role_id: rid)
        assert_not_nil rm
        assert_equal "Software Engineer", rm.name
        assert_equal "E", rm.code
        assert_equal "ic", rm.track
      end
    end
  end

  context "LevelAdded" do
    should "create a Level read model" do
      rid = SecureRandom.uuid_v7
      lid = SecureRandom.uuid_v7
      emit(Frameworks::Events::LevelAdded,
        framework_id: @framework_id, level_id: lid, role_id: rid,
        ordinal: 3, title: "Senior Engineer", code: "E3", is_entry: false)

      within_tenant do
        rm = FrameworkState::Level.find_by(level_id: lid)
        assert_not_nil rm
        assert_equal 3, rm.ordinal
        assert_equal "Senior Engineer", rm.title
        assert_equal "E3", rm.code
        assert_equal false, rm.is_entry
      end
    end
  end

  context "CapabilityCategoryAdded" do
    should "create a CapabilityCategory read model" do
      cid = SecureRandom.uuid_v7
      emit(Frameworks::Events::CapabilityCategoryAdded,
        framework_id: @framework_id, category_id: cid,
        name: "Thinking & Delivery", description: "How we think", ordinal: 1)

      within_tenant do
        rm = FrameworkState::CapabilityCategory.find_by(category_id: cid)
        assert_not_nil rm
        assert_equal "Thinking & Delivery", rm.name
        assert_equal 1, rm.ordinal
      end
    end
  end

  context "CapabilityAdded" do
    should "create a Capability read model with active status" do
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      stable_id = SecureRandom.uuid_v7
      emit(Frameworks::Events::CapabilityAdded,
        framework_id: @framework_id, capability_id: cap_id, stable_id: stable_id,
        category_id: cat_id, name: "Strategic Thinking", description: "Long-term thinking")

      within_tenant do
        rm = FrameworkState::Capability.find_by(capability_id: cap_id)
        assert_not_nil rm
        assert_equal "Strategic Thinking", rm.name
        assert_equal "active", rm.status
        assert_equal stable_id, rm.stable_id
      end
    end
  end

  context "CapabilityUpdated" do
    should "update the Capability read model" do
      cap_id = SecureRandom.uuid_v7
      emit(Frameworks::Events::CapabilityAdded,
        framework_id: @framework_id, capability_id: cap_id, stable_id: SecureRandom.uuid_v7,
        category_id: SecureRandom.uuid_v7, name: "Original", description: "Original desc")
      emit(Frameworks::Events::CapabilityUpdated,
        framework_id: @framework_id, capability_id: cap_id,
        name: "Renamed", description: "New desc")

      within_tenant do
        rm = FrameworkState::Capability.find_by(capability_id: cap_id)
        assert_equal "Renamed", rm.name
        assert_equal "New desc", rm.description
      end
    end

    should "only update fields present in event data" do
      cap_id = SecureRandom.uuid_v7
      emit(Frameworks::Events::CapabilityAdded,
        framework_id: @framework_id, capability_id: cap_id, stable_id: SecureRandom.uuid_v7,
        category_id: SecureRandom.uuid_v7, name: "Original", description: "Keep me")
      emit(Frameworks::Events::CapabilityUpdated,
        framework_id: @framework_id, capability_id: cap_id, name: "Renamed")

      within_tenant do
        rm = FrameworkState::Capability.find_by(capability_id: cap_id)
        assert_equal "Renamed", rm.name
        assert_equal "Keep me", rm.description
      end
    end

    should "silently skip when parent capability is missing (draft-deferred)" do
      cap_id = SecureRandom.uuid_v7
      emit(Frameworks::Events::CapabilityUpdated,
        framework_id: @framework_id, capability_id: cap_id, name: "Orphaned")

      within_tenant do
        assert_nil FrameworkState::Capability.find_by(capability_id: cap_id),
          "Capability should not be created when parent is missing"
      end
    end
  end

  context "CapabilityArchived" do
    should "set status to archived" do
      cap_id = SecureRandom.uuid_v7
      emit(Frameworks::Events::CapabilityAdded,
        framework_id: @framework_id, capability_id: cap_id, stable_id: SecureRandom.uuid_v7,
        category_id: SecureRandom.uuid_v7, name: "Old Cap")
      emit(Frameworks::Events::CapabilityArchived,
        framework_id: @framework_id, capability_id: cap_id, reason: "Superseded")

      within_tenant do
        rm = FrameworkState::Capability.find_by(capability_id: cap_id)
        assert_equal "archived", rm.status
      end
    end
  end

  context "CapabilityRoleBindingCreated" do
    should "create a binding read model" do
      bid = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      emit(Frameworks::Events::CapabilityRoleBindingCreated,
        framework_id: @framework_id, binding_id: bid, capability_id: cap_id,
        role_id: rid, weight: 1.5, individual_tolerance: 2.0)

      within_tenant do
        rm = FrameworkState::CapabilityRoleBinding.find_by(binding_id: bid)
        assert_not_nil rm
        assert_equal 1.5, rm.weight.to_f
        assert_equal 2.0, rm.deficit_threshold.to_f
      end
    end
  end

  context "CapabilityRoleBindingRemoved" do
    should "destroy the binding read model" do
      bid = SecureRandom.uuid_v7
      emit(Frameworks::Events::CapabilityRoleBindingCreated,
        framework_id: @framework_id, binding_id: bid, capability_id: SecureRandom.uuid_v7,
        role_id: SecureRandom.uuid_v7, weight: 1.0)
      emit(Frameworks::Events::CapabilityRoleBindingRemoved,
        framework_id: @framework_id, binding_id: bid)

      within_tenant do
        assert_nil FrameworkState::CapabilityRoleBinding.find_by(binding_id: bid)
      end
    end
  end

  context "BehaviouralExpectationSet" do
    should "create an expectation read model" do
      eid = SecureRandom.uuid_v7
      sid = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      emit(Frameworks::Events::BehaviouralExpectationSet,
        framework_id: @framework_id, expectation_id: eid, stable_id: sid,
        capability_id: cap_id, level_ordinal: 3,
        description: "Breaks down problems and explains reasoning.")

      within_tenant do
        rm = FrameworkState::BehaviouralExpectation.find_by(expectation_id: eid)
        assert_not_nil rm
        assert_equal 3, rm.level_ordinal
        assert_equal "Breaks down problems and explains reasoning.", rm.description
      end
    end
  end

  context "BehaviouralExpectationUpdated" do
    should "update the expectation description" do
      eid = SecureRandom.uuid_v7
      emit(Frameworks::Events::BehaviouralExpectationSet,
        framework_id: @framework_id, expectation_id: eid, stable_id: SecureRandom.uuid_v7,
        capability_id: SecureRandom.uuid_v7, level_ordinal: 1, description: "Original")
      emit(Frameworks::Events::BehaviouralExpectationUpdated,
        framework_id: @framework_id, expectation_id: eid,
        new_description: "Updated wording", rationale: "Clearer")

      within_tenant do
        rm = FrameworkState::BehaviouralExpectation.find_by(expectation_id: eid)
        assert_equal "Updated wording", rm.description
      end
    end
  end

  context "RoleIllustrationAdded" do
    should "create an illustration read model" do
      iid = SecureRandom.uuid_v7
      sid = SecureRandom.uuid_v7
      eid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7

      # Illustrations are dependent-editorial: parent expectation must exist
      within_tenant do
        FrameworkState::BehaviouralExpectation.create!(
          expectation_id: eid, stable_id: SecureRandom.uuid_v7,
          capability_id: SecureRandom.uuid_v7, level_ordinal: 1, description: "Parent"
        )
      end

      emit(Frameworks::Events::RoleIllustrationAdded,
        framework_id: @framework_id, illustration_id: iid, stable_id: sid,
        expectation_id: eid, role_id: rid, ordinal: 1,
        description: "Seeks guidance from a tech lead")

      within_tenant do
        rm = FrameworkState::RoleIllustration.find_by(illustration_id: iid)
        assert_not_nil rm
        assert_equal "Seeks guidance from a tech lead", rm.description
        assert_equal 1, rm.ordinal
      end
    end

    should "silently skip when parent expectation is missing (draft-deferred)" do
      iid = SecureRandom.uuid_v7
      emit(Frameworks::Events::RoleIllustrationAdded,
        framework_id: @framework_id, illustration_id: iid, stable_id: SecureRandom.uuid_v7,
        expectation_id: SecureRandom.uuid_v7, role_id: SecureRandom.uuid_v7,
        ordinal: 1, description: "Orphaned")

      within_tenant do
        assert_nil FrameworkState::RoleIllustration.find_by(illustration_id: iid),
          "Illustration should not be created when parent expectation is missing"
      end
    end
  end

  context "RoleIllustrationRemoved" do
    should "destroy the illustration read model" do
      eid = SecureRandom.uuid_v7
      iid = SecureRandom.uuid_v7

      within_tenant do
        FrameworkState::BehaviouralExpectation.create!(
          expectation_id: eid, stable_id: SecureRandom.uuid_v7,
          capability_id: SecureRandom.uuid_v7, level_ordinal: 1, description: "Parent"
        )
      end

      emit(Frameworks::Events::RoleIllustrationAdded,
        framework_id: @framework_id, illustration_id: iid, stable_id: SecureRandom.uuid_v7,
        expectation_id: eid, role_id: SecureRandom.uuid_v7,
        ordinal: 1, description: "Example")
      emit(Frameworks::Events::RoleIllustrationRemoved,
        framework_id: @framework_id, illustration_id: iid, reason: "Outdated")

      within_tenant do
        assert_nil FrameworkState::RoleIllustration.find_by(illustration_id: iid)
      end
    end
  end

  context "RoleIllustrationReordered" do
    should "update ordinals" do
      eid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      iid1 = SecureRandom.uuid_v7
      iid2 = SecureRandom.uuid_v7

      within_tenant do
        FrameworkState::BehaviouralExpectation.create!(
          expectation_id: eid, stable_id: SecureRandom.uuid_v7,
          capability_id: SecureRandom.uuid_v7, level_ordinal: 1, description: "Parent"
        )
      end

      emit(Frameworks::Events::RoleIllustrationAdded,
        framework_id: @framework_id, illustration_id: iid1, stable_id: SecureRandom.uuid_v7,
        expectation_id: eid, role_id: rid, ordinal: 1, description: "First")
      emit(Frameworks::Events::RoleIllustrationAdded,
        framework_id: @framework_id, illustration_id: iid2, stable_id: SecureRandom.uuid_v7,
        expectation_id: eid, role_id: rid, ordinal: 2, description: "Second")
      emit(Frameworks::Events::RoleIllustrationReordered,
        framework_id: @framework_id, expectation_id: eid, role_id: rid,
        new_ordering: [ iid2, iid1 ])

      within_tenant do
        assert_equal 2, FrameworkState::RoleIllustration.find_by(illustration_id: iid1).ordinal
        assert_equal 1, FrameworkState::RoleIllustration.find_by(illustration_id: iid2).ordinal
      end
    end
  end

  context "CapabilityCategoryReordered" do
    should "update category ordinals" do
      cat1 = SecureRandom.uuid_v7
      cat2 = SecureRandom.uuid_v7

      emit(Frameworks::Events::CapabilityCategoryAdded,
        framework_id: @framework_id, category_id: cat1, name: "Thinking")
      emit(Frameworks::Events::CapabilityCategoryAdded,
        framework_id: @framework_id, category_id: cat2, name: "Delivery")
      emit(Frameworks::Events::CapabilityCategoryReordered,
        framework_id: @framework_id, new_ordering: [ cat2, cat1 ])

      within_tenant do
        assert_equal 2, FrameworkState::CapabilityCategory.find_by(category_id: cat1).ordinal
        assert_equal 1, FrameworkState::CapabilityCategory.find_by(category_id: cat2).ordinal
      end
    end
  end

  context "CapabilityReordered" do
    should "update capability ordinals, skipping ids with no read-model row" do
      cat_id = SecureRandom.uuid_v7
      cap1 = SecureRandom.uuid_v7
      cap2 = SecureRandom.uuid_v7
      draft_cap = SecureRandom.uuid_v7 # never added → no row

      emit(Frameworks::Events::CapabilityCategoryAdded,
        framework_id: @framework_id, category_id: cat_id, name: "Thinking")
      emit(Frameworks::Events::CapabilityAdded,
        framework_id: @framework_id, capability_id: cap1, stable_id: SecureRandom.uuid_v7,
        category_id: cat_id, name: "Alpha")
      emit(Frameworks::Events::CapabilityAdded,
        framework_id: @framework_id, capability_id: cap2, stable_id: SecureRandom.uuid_v7,
        category_id: cat_id, name: "Beta")
      emit(Frameworks::Events::CapabilityReordered,
        framework_id: @framework_id, category_id: cat_id,
        new_ordering: [ draft_cap, cap2, cap1 ])

      within_tenant do
        assert_equal 3, FrameworkState::Capability.find_by(capability_id: cap1).ordinal
        assert_equal 2, FrameworkState::Capability.find_by(capability_id: cap2).ordinal
        assert_nil FrameworkState::Capability.find_by(capability_id: draft_cap)
      end
    end
  end

  context "full lifecycle" do
    should "build complete framework from events" do
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      lid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      bid = SecureRandom.uuid_v7
      eid = SecureRandom.uuid_v7
      iid = SecureRandom.uuid_v7

      emit(Frameworks::Events::FrameworkCreated, framework_id: @framework_id, name: "me&u 2025")
      emit(Frameworks::Events::RoleFamilyAdded, framework_id: @framework_id, role_family_id: rfid, name: "Engineering")
      emit(Frameworks::Events::RoleAdded, framework_id: @framework_id, role_id: rid, role_family_id: rfid, name: "Software Engineer", code: "E", track: "ic")
      emit(Frameworks::Events::LevelAdded, framework_id: @framework_id, level_id: lid, role_id: rid, ordinal: 1, title: "Engineer I", code: "E1", is_entry: true)
      emit(Frameworks::Events::CapabilityCategoryAdded, framework_id: @framework_id, category_id: cat_id, name: "Thinking", ordinal: 1)
      emit(Frameworks::Events::CapabilityAdded, framework_id: @framework_id, capability_id: cap_id, stable_id: SecureRandom.uuid_v7, category_id: cat_id, name: "Strategic Thinking")
      emit(Frameworks::Events::CapabilityRoleBindingCreated, framework_id: @framework_id, binding_id: bid, capability_id: cap_id, role_id: rid, weight: 1.0, requirement_type: "must_have")
      emit(Frameworks::Events::BehaviouralExpectationSet, framework_id: @framework_id, expectation_id: eid, stable_id: SecureRandom.uuid_v7, capability_id: cap_id, level_ordinal: 1, description: "Asks questions")
      emit(Frameworks::Events::RoleIllustrationAdded, framework_id: @framework_id, illustration_id: iid, stable_id: SecureRandom.uuid_v7, expectation_id: eid, role_id: rid, ordinal: 1, description: "Seeks guidance from tech lead")

      within_tenant do
        framework = FrameworkState::Framework.find_by!(framework_id: @framework_id)
        assert_equal 1, framework.role_families.count
        assert_equal 1, framework.capability_categories.count

        role_family = framework.role_families.first
        assert_equal 1, role_family.roles.count

        role = role_family.roles.first
        assert_equal 1, role.levels.count
        assert_equal 1, role.bindings.count

        category = framework.capability_categories.first
        assert_equal 1, category.capabilities.count

        capability = category.capabilities.first
        assert_equal 1, capability.expectations.count

        expectation = capability.expectations.first
        assert_equal 1, expectation.illustrations.count
        assert_equal "Seeks guidance from tech lead", expectation.illustrations.first.description
      end
    end
  end

  # ── Versioning ──

  context "DraftVersionStarted" do
    should "set draft_in_progress on framework" do
      emit(Frameworks::Events::FrameworkCreated, framework_id: @framework_id, name: "Test")
      emit(Frameworks::Events::DraftVersionStarted,
        framework_id: @framework_id, target_version: 1, started_by: "user-1")

      within_tenant do
        fw = FrameworkState::Framework.find_by(framework_id: @framework_id)
        assert fw.draft_in_progress
        assert_equal 1, fw.draft_version
      end
    end
  end

  context "shape-changing events during draft" do
    should "skip shape-changing events when draft is in progress" do
      emit(Frameworks::Events::FrameworkCreated, framework_id: @framework_id, name: "Test")
      emit(Frameworks::Events::DraftVersionStarted,
        framework_id: @framework_id, target_version: 1, started_by: "user-1")

      # CapabilityCategoryAdded is editorial — applies immediately
      cat_id = SecureRandom.uuid_v7
      emit(Frameworks::Events::CapabilityCategoryAdded,
        framework_id: @framework_id, category_id: cat_id, name: "Cat", ordinal: 1)

      # CapabilityAdded is shape-changing — deferred
      cap_id = SecureRandom.uuid_v7
      emit(Frameworks::Events::CapabilityAdded,
        framework_id: @framework_id, capability_id: cap_id, stable_id: SecureRandom.uuid_v7,
        category_id: cat_id, name: "Cap")

      within_tenant do
        assert_not_nil FrameworkState::CapabilityCategory.find_by(category_id: cat_id),
          "Category (editorial) SHOULD be created during draft"
        assert_nil FrameworkState::Capability.find_by(capability_id: cap_id),
          "Capability (shape-changing) should NOT be created during draft"
      end
    end
  end

  context "editorial events during draft" do
    should "apply RoleFamilyAdded immediately while draft is in progress" do
      emit(Frameworks::Events::FrameworkCreated, framework_id: @framework_id, name: "Test")
      emit(Frameworks::Events::DraftVersionStarted,
        framework_id: @framework_id, target_version: 1, started_by: "user-1")

      rfid = SecureRandom.uuid_v7
      emit(Frameworks::Events::RoleFamilyAdded,
        framework_id: @framework_id, role_family_id: rfid, name: "Engineering")

      within_tenant do
        assert_not_nil FrameworkState::RoleFamily.find_by(role_family_id: rfid),
          "RoleFamily (editorial) should be created immediately during draft"
      end
    end

    should "apply BehaviouralExpectationUpdated immediately while draft is in progress" do
      cap_id = SecureRandom.uuid_v7
      emit(Frameworks::Events::FrameworkCreated, framework_id: @framework_id, name: "Test")
      # Set up the expectation via publish first so the shape-changing event lands
      emit(Frameworks::Events::DraftVersionStarted,
        framework_id: @framework_id, target_version: 1, started_by: "user-1")

      eid = SecureRandom.uuid_v7
      # BehaviouralExpectationSet is shape-changing; during draft the projection
      # skips it. We need to exercise the editorial path, so use an expectation
      # that already exists post-publish. Simulate by manually creating the row.
      within_tenant do
        FrameworkState::BehaviouralExpectation.create!(
          expectation_id: eid,
          stable_id: SecureRandom.uuid_v7,
          capability_id: cap_id,
          level_ordinal: 1,
          description: "Original"
        )
      end

      emit(Frameworks::Events::BehaviouralExpectationUpdated,
        framework_id: @framework_id, expectation_id: eid,
        new_description: "Updated during draft", rationale: "typo fix")

      within_tenant do
        rm = FrameworkState::BehaviouralExpectation.find_by(expectation_id: eid)
        assert_equal "Updated during draft", rm.description
      end
    end
  end

  context "FrameworkVersionPublished" do
    should "rebuild projection including shape-changing events from the draft" do
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        # create_framework opens bootstrap v1 draft automatically
        handler.create_framework(@framework_id, "Test Framework")

        rfid = SecureRandom.uuid_v7
        rid = SecureRandom.uuid_v7
        cat_id = SecureRandom.uuid_v7
        handler.add_role_family(@framework_id, rfid, "Engineering")
        handler.add_role(@framework_id, rid, rfid, "E", "E", "ic")
        handler.add_capability_category(@framework_id, cat_id, "Thinking")

        # Editorial events are visible immediately
        assert_not_nil FrameworkState::RoleFamily.find_by(role_family_id: rfid)
        assert_not_nil FrameworkState::CapabilityCategory.find_by(category_id: cat_id)

        # CapabilityAdded is shape-changing — deferred until publish
        cap_id = SecureRandom.uuid_v7
        handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic")
        assert_nil FrameworkState::Capability.find_by(capability_id: cap_id),
          "Capability should NOT exist before publish"

        # Publish — triggers rebuild from event stream
        handler.publish_version(@framework_id, "user-1")

        fw = FrameworkState::Framework.find_by(framework_id: @framework_id)
        assert_equal 1, fw.current_published_version
        assert_not fw.draft_in_progress
        assert_nil fw.draft_version

        # Rebuild replayed all events — shape-changing events are now visible
        assert_not_nil FrameworkState::Capability.find_by(capability_id: cap_id),
          "Capability should exist after publish rebuild"
        # Editorial events that applied live also survive the rebuild
        assert_not_nil FrameworkState::RoleFamily.find_by(role_family_id: rfid)
      end
    end

    should "auto-open implicit draft when approving a shape-changing suggestion after v1" do
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        handler.create_framework(@framework_id, "Test Framework")
        rfid = SecureRandom.uuid_v7
        rid = SecureRandom.uuid_v7
        cat_id = SecureRandom.uuid_v7
        handler.add_role_family(@framework_id, rfid, "Engineering")
        handler.add_role(@framework_id, rid, rfid, "E", "E", "ic")
        handler.add_capability_category(@framework_id, cat_id, "Thinking")
        handler.publish_version(@framework_id, "user-1")

        # v1 is published, no draft active.
        fw = FrameworkState::Framework.find_by(framework_id: @framework_id)
        assert_equal 1, fw.current_published_version
        assert_not fw.draft_in_progress

        # Author suggests a new capability; reviewer approves.
        # mode: :suggesting prevents the open-framework auto-approval path so
        # the test exercises an explicit reviewer approval.
        sug_id = SecureRandom.uuid_v7
        reviewer_person = create(:person, tenant: @tenant)
        handler.suggest_create(@framework_id, sug_id, "capability",
          { name: "Resilience" }, parent_id: cat_id, author_id: @author_person.id.to_s, mode: :suggesting)
        handler.approve_suggestion(@framework_id, sug_id, reviewer_person.id.to_s)

        # The implicit draft is now open in the projection.
        fw.reload
        assert fw.draft_in_progress, "approval should have auto-opened a draft"
        assert_equal 2, fw.draft_version

        # The new capability is shape-changing — deferred until publish.
        assert_equal 0, FrameworkState::Capability
          .joins(:category).where(framework_capability_categories: { framework_id: @framework_id }).count,
          "Capability should NOT be visible while the auto-opened draft is in progress"

        # Publishing the implicit draft makes it visible via rebuild.
        handler.publish_version(@framework_id, "user-1")

        fw.reload
        assert_equal 2, fw.current_published_version
        assert_not fw.draft_in_progress
        assert_equal 1, FrameworkState::Capability
          .joins(:category).where(framework_capability_categories: { framework_id: @framework_id }).count
        assert_not_nil FrameworkState::Capability.find_by(name: "Resilience")
      end
    end

    should "preserve editorial changes made after v1 publish" do
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        handler.create_framework(@framework_id, "Test Framework")
        rfid = SecureRandom.uuid_v7
        handler.add_role_family(@framework_id, rfid, "Engineering")
        handler.publish_version(@framework_id, "user-1")

        # Post-v1 editorial update — live
        handler.update_role_family(@framework_id, rfid, name: "Eng (post-v1)")

        # Start v2 draft with a shape-changing event, then publish v2
        handler.start_draft(@framework_id, 2, "user-1")
        cat_id = SecureRandom.uuid_v7
        handler.add_capability_category(@framework_id, cat_id, "Delivery")
        handler.publish_version(@framework_id, "user-1")

        # Editorial update from between v1 and v2 must survive the v2 rebuild
        rf = FrameworkState::RoleFamily.find_by(role_family_id: rfid)
        assert_equal "Eng (post-v1)", rf.name
        assert_equal 2, FrameworkState::Framework.find_by(framework_id: @framework_id).current_published_version
      end
    end
  end

  context "MigrationMappingDefined" do
    should "persist a migration mapping read model" do
      emit(Frameworks::Events::FrameworkCreated, framework_id: @framework_id, name: "Test")
      emit(Frameworks::Events::DraftVersionStarted,
        framework_id: @framework_id, target_version: 1, started_by: "user-1")

      mid = SecureRandom.uuid_v7
      from_sid = SecureRandom.uuid_v7
      to_sid = SecureRandom.uuid_v7
      emit(Frameworks::Events::MigrationMappingDefined,
        framework_id: @framework_id, mapping_id: mid,
        from_stable_id: from_sid, to_stable_id: to_sid,
        mapping_type: "evolved", requires_reassessment: true, reason: "Scope broadened")

      within_tenant do
        mapping = FrameworkState::MigrationMapping.find_by(mapping_id: mid)
        assert_not_nil mapping
        assert_equal from_sid, mapping.from_stable_id
        assert_equal to_sid, mapping.to_stable_id
        assert_equal "evolved", mapping.mapping_type
        assert mapping.requires_reassessment
        assert_equal "Scope broadened", mapping.reason
        assert_equal 1, mapping.published_version
      end
    end
  end

  # ── EditSuggested current_value snapshot per entity type ──

  context "EditSuggested current_value snapshot" do
    setup do
      @sid = SecureRandom.uuid_v7
      @author_id = @author_person.id.to_s
    end

    should "snapshot current value for role_illustration" do
      ill_id = SecureRandom.uuid_v7
      within_tenant do
        FrameworkState::RoleIllustration.create!(
          illustration_id: ill_id, stable_id: SecureRandom.uuid_v7,
          expectation_id: SecureRandom.uuid_v7, role_id: SecureRandom.uuid_v7,
          ordinal: 1, description: "Original wording"
        )
      end
      emit_suggestion("role_illustration", ill_id, "description", "New wording")

      within_tenant do
        rec = FrameworkState::SuggestedEdit.find_by(suggestion_id: @sid)
        assert_equal "Original wording", rec.current_value
        assert_equal "New wording", rec.suggested_value
      end
    end

    should "snapshot current value for behavioural_expectation" do
      eid = SecureRandom.uuid_v7
      within_tenant do
        FrameworkState::BehaviouralExpectation.create!(
          expectation_id: eid, stable_id: SecureRandom.uuid_v7,
          capability_id: SecureRandom.uuid_v7, level_ordinal: 1, description: "Original"
        )
      end
      emit_suggestion("behavioural_expectation", eid, "description", "Sharper")

      within_tenant do
        rec = FrameworkState::SuggestedEdit.find_by(suggestion_id: @sid)
        assert_equal "Original", rec.current_value
      end
    end

    should "snapshot current value for capability name" do
      cap_id = SecureRandom.uuid_v7
      within_tenant do
        FrameworkState::Capability.create!(
          capability_id: cap_id, stable_id: SecureRandom.uuid_v7,
          category_id: SecureRandom.uuid_v7, name: "Original Cap", status: "active"
        )
      end
      emit_suggestion("capability", cap_id, "name", "Renamed Cap")

      within_tenant do
        rec = FrameworkState::SuggestedEdit.find_by(suggestion_id: @sid)
        assert_equal "Original Cap", rec.current_value
      end
    end

    should "snapshot current value for capability_category description" do
      cat_id = SecureRandom.uuid_v7
      within_tenant do
        FrameworkState::CapabilityCategory.create!(
          framework_id: @framework_id, category_id: cat_id,
          name: "Thinking", description: "How we think", ordinal: 1
        )
      end
      emit_suggestion("capability_category", cat_id, "description", "How we reason")

      within_tenant do
        rec = FrameworkState::SuggestedEdit.find_by(suggestion_id: @sid)
        assert_equal "How we think", rec.current_value
      end
    end

    should "snapshot current value for role" do
      rid = SecureRandom.uuid_v7
      within_tenant do
        FrameworkState::Role.create!(
          role_id: rid, role_family_id: SecureRandom.uuid_v7,
          name: "Engineer", code: "E", track: "ic"
        )
      end
      emit_suggestion("role", rid, "name", "Software Engineer")

      within_tenant do
        rec = FrameworkState::SuggestedEdit.find_by(suggestion_id: @sid)
        assert_equal "Engineer", rec.current_value
      end
    end

    should "snapshot current value for role_family" do
      rfid = SecureRandom.uuid_v7
      within_tenant do
        FrameworkState::RoleFamily.create!(
          framework_id: @framework_id, role_family_id: rfid,
          name: "Engineering", description: "Tech roles"
        )
      end
      emit_suggestion("role_family", rfid, "description", "Builds product")

      within_tenant do
        rec = FrameworkState::SuggestedEdit.find_by(suggestion_id: @sid)
        assert_equal "Tech roles", rec.current_value
      end
    end

    should "snapshot current value for level" do
      lid = SecureRandom.uuid_v7
      within_tenant do
        FrameworkState::Level.create!(
          level_id: lid, role_id: SecureRandom.uuid_v7,
          ordinal: 3, title: "Senior Engineer", code: "E3", is_entry: false
        )
      end
      emit_suggestion("level", lid, "title", "Staff Engineer")

      within_tenant do
        rec = FrameworkState::SuggestedEdit.find_by(suggestion_id: @sid)
        assert_equal "Senior Engineer", rec.current_value
      end
    end

    should "tolerate missing parent capability (current_value nil)" do
      cap_id = SecureRandom.uuid_v7
      emit_suggestion("capability", cap_id, "name", "Orphaned")

      within_tenant do
        rec = FrameworkState::SuggestedEdit.find_by(suggestion_id: @sid)
        assert_not_nil rec
        assert_nil rec.current_value
        assert_equal "Orphaned", rec.suggested_value
      end
    end
  end

  context "rebuild contract" do
    should "reset! + replay produces identical read-model state" do
      rfid = SecureRandom.uuid_v7
      rid  = SecureRandom.uuid_v7
      lid  = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      bid  = SecureRandom.uuid_v7
      eid  = SecureRandom.uuid_v7
      iid  = SecureRandom.uuid_v7

      append_and_project(Frameworks::Events::FrameworkCreated,
        framework_id: @framework_id, name: "me&u 2025")
      append_and_project(Frameworks::Events::FrameworkRenamed,
        framework_id: @framework_id, name: "me&u Career Paths")
      append_and_project(Frameworks::Events::RoleFamilyAdded,
        framework_id: @framework_id, role_family_id: rfid, name: "Engineering")
      append_and_project(Frameworks::Events::RoleAdded,
        framework_id: @framework_id, role_id: rid, role_family_id: rfid,
        name: "Software Engineer", code: "E", track: "ic")
      append_and_project(Frameworks::Events::LevelAdded,
        framework_id: @framework_id, level_id: lid, role_id: rid,
        ordinal: 1, title: "Engineer I", code: "E1", is_entry: true)
      append_and_project(Frameworks::Events::CapabilityCategoryAdded,
        framework_id: @framework_id, category_id: cat_id, name: "Thinking", ordinal: 1)
      append_and_project(Frameworks::Events::CapabilityAdded,
        framework_id: @framework_id, capability_id: cap_id,
        stable_id: SecureRandom.uuid_v7, category_id: cat_id, name: "Strategic Thinking")
      append_and_project(Frameworks::Events::CapabilityRoleBindingCreated,
        framework_id: @framework_id, binding_id: bid, capability_id: cap_id,
        role_id: rid, weight: 1.0, requirement_type: "must_have")
      append_and_project(Frameworks::Events::BehaviouralExpectationSet,
        framework_id: @framework_id, expectation_id: eid,
        stable_id: SecureRandom.uuid_v7, capability_id: cap_id,
        level_ordinal: 1, description: "Asks questions")
      append_and_project(Frameworks::Events::RoleIllustrationAdded,
        framework_id: @framework_id, illustration_id: iid,
        stable_id: SecureRandom.uuid_v7, expectation_id: eid, role_id: rid,
        ordinal: 1, description: "Seeks guidance from tech lead")

      before_snapshot = snapshot_read_models(Frameworks::Projections::PublishedState, @tenant)
      assert_equal 1, before_snapshot[:frameworks].size
      assert_equal 1, before_snapshot[:illustrations].size
      within_tenant do
        assert_equal "me&u Career Paths", FrameworkState::Framework.find_by(framework_id: @framework_id).name
      end

      Frameworks::Projections::PublishedState.reset!(tenant: @tenant)
      within_tenant do
        assert_equal 0, FrameworkState::Framework.count
        assert_equal 0, FrameworkState::RoleIllustration.count
        assert_equal 0, FrameworkState::Collaborator.count
      end

      Projections::Replayer.replay(
        projection_class: Frameworks::Projections::PublishedState,
        tenant: @tenant
      )

      after_snapshot = snapshot_read_models(Frameworks::Projections::PublishedState, @tenant)
      assert_equal before_snapshot, after_snapshot
    end

    should "tolerate duplicate CollaboratorAdded events in the stream during replay" do
      person = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant) }

      append_and_project(Frameworks::Events::FrameworkCreated,
        framework_id: @framework_id, name: "me&u 2025")
      append_and_project(Frameworks::Events::CollaboratorAdded,
        framework_id: @framework_id, person_id: person.id,
        collaborator_role: "editor", scope_type: nil, scope_id: nil, added_by: "tester")
      # Bypass the projection's live call for the duplicate — it would
      # have raised before this fix. Append straight to the stream so
      # replay sees both events.
      duplicate = Frameworks::Events::CollaboratorAdded.new(
        data: {
          framework_id: @framework_id, person_id: person.id,
          collaborator_role: "editor", scope_type: nil, scope_id: nil, added_by: "tester"
        },
        metadata: { tenant_id: @tenant.id }
      )
      stream = EventStreamNaming.framework_stream(@framework_id, tenant: @tenant)
      Rails.configuration.event_store.append(duplicate, stream_name: stream)

      Frameworks::Projections::PublishedState.reset!(tenant: @tenant)
      within_tenant { assert_equal 0, FrameworkState::Collaborator.count }

      Projections::Replayer.replay(
        projection_class: Frameworks::Projections::PublishedState,
        tenant: @tenant
      )

      within_tenant do
        assert_equal 1, FrameworkState::Collaborator.where(person_id: person.id, role: "editor").count,
          "replay should produce exactly one collaborator row regardless of duplicate events"
      end
    end
  end

  context "real-time activity broadcast" do
    should "broadcast on a feed-relevant event carrying framework_id" do
      event = Frameworks::Events::CapabilityUpdated.new(
        data: { framework_id: @framework_id, capability_id: SecureRandom.uuid_v7, name: "X" },
        metadata: { tenant_id: @tenant.id })

      # Two replaces per feed-relevant event: the pane's sync signal AND the
      # header's pending badge, which lives outside the pane's frame and would
      # otherwise stay stale until a full reload (#381).
      broadcasts = capture_activity_broadcasts { @projection.send(:broadcast_framework_activity, event) }
      assert_equal [ [ "framework_activity", @framework_id ] ] * 2, broadcasts
      assert_equal [ "framework-activity-sync-signal", "framework-pending-badge" ],
                   capture_activity_broadcast_targets { @projection.send(:broadcast_framework_activity, event) }
    end

    should "not broadcast for an event the feed does not surface" do
      # FrameworkCreated is the stable non-feed example — RoleAdded and then
      # LevelAdded (the previous examples) each became feed-relevant as the
      # org-structure passes landed.
      event = Frameworks::Events::FrameworkCreated.new(
        data: { framework_id: @framework_id, name: "X" },
        metadata: { tenant_id: @tenant.id })

      broadcasts = capture_activity_broadcasts { @projection.send(:broadcast_framework_activity, event) }
      assert_empty broadcasts
    end

    should "resolve framework_id from the SuggestedEdit row for a resolved-suggestion event" do
      sid = SecureRandom.uuid_v7
      within_tenant do
        create(:framework_suggested_edit, tenant: @tenant, framework_id: @framework_id,
          suggestion_id: sid, author_id: @author_person.id)
      end
      event = Frameworks::Events::SuggestionApproved.new(
        data: { suggestion_id: sid, reviewer_id: @author_person.id },
        metadata: { tenant_id: @tenant.id })

      broadcasts = within_tenant do
        capture_activity_broadcasts { @projection.send(:broadcast_framework_activity, event) }
      end
      assert_equal [ [ "framework_activity", @framework_id ] ] * 2, broadcasts
    end

    should "stay silent during replay" do
      event = Frameworks::Events::CapabilityUpdated.new(
        data: { framework_id: @framework_id, capability_id: SecureRandom.uuid_v7, name: "X" },
        metadata: { tenant_id: @tenant.id })

      broadcasts = capture_activity_broadcasts do
        Projections::Replayer.with_replay_mode { @projection.send(:broadcast_framework_activity, event) }
      end
      assert_empty broadcasts
    end
  end

  private

  # Captures the positional args of every Turbo broadcast emitted in the block.
  def capture_activity_broadcasts
    broadcasts = []
    Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*args, **_kw) { broadcasts << args }) do
      yield
    end
    broadcasts
  end

  # Captures which DOM ids the block's broadcasts replace.
  def capture_activity_broadcast_targets
    targets = []
    Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*_args, **kw) { targets << kw[:target] }) do
      yield
    end
    targets
  end

  # Emits an event through the projection.
  #
  # @param event_class [Class] the event class
  # @param data [Hash] event data
  def emit(event_class, **data)
    event = event_class.new(data: data, metadata: { tenant_id: @tenant.id })
    @projection.call(event)
  end

  # Executes a block within the test tenant context.
  def within_tenant(&block)
    ActsAsTenant.with_tenant(@tenant, &block)
  end

  # Emits an EditSuggested event with the standard test fixture ids.
  def emit_suggestion(entity_type, entity_id, field, suggested_value)
    emit(Frameworks::Events::EditSuggested,
      framework_id: @framework_id,
      suggestion_id: @sid,
      target_entity_type: entity_type,
      target_entity_id: entity_id,
      field: field,
      suggested_value: suggested_value,
      author_id: @author_id)
  end

  # Appends an event to the real store AND calls the projection directly.
  # Uses `append` rather than `publish` so subscribers (especially sync
  # handlers that dispatch domain commands) don't fire. See the round-trip
  # test pattern in `docs/guidelines/event-sourcing.md`.
  def append_and_project(event_class, **data)
    event = event_class.new(data: data, metadata: { tenant_id: @tenant.id })
    stream = EventStreamNaming.framework_stream(@framework_id, tenant: @tenant)
    Rails.configuration.event_store.append(event, stream_name: stream)
    @projection.call(event)
  end
end
