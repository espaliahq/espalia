# frozen_string_literal: true

require "test_helper"

class Frameworks::Projections::PublishedStateTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @projection = Frameworks::Projections::PublishedState.new
    @framework_id = SecureRandom.uuid_v7
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
        assert_equal 2.0, rm.individual_tolerance.to_f
      end
    end
  end

  context "CapabilityRoleBindingRemoved" do
    should "destroy the binding read model" do
      bid = SecureRandom.uuid_v7
      emit(Frameworks::Events::CapabilityRoleBindingCreated,
        framework_id: @framework_id, binding_id: bid, capability_id: SecureRandom.uuid_v7,
        role_id: SecureRandom.uuid_v7, weight: 1.0, individual_tolerance: nil)
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
  end

  context "RoleIllustrationRemoved" do
    should "destroy the illustration read model" do
      iid = SecureRandom.uuid_v7
      emit(Frameworks::Events::RoleIllustrationAdded,
        framework_id: @framework_id, illustration_id: iid, stable_id: SecureRandom.uuid_v7,
        expectation_id: SecureRandom.uuid_v7, role_id: SecureRandom.uuid_v7,
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

  context "structural events during draft" do
    should "skip structural events when draft is in progress" do
      emit(Frameworks::Events::FrameworkCreated, framework_id: @framework_id, name: "Test")
      emit(Frameworks::Events::DraftVersionStarted,
        framework_id: @framework_id, target_version: 1, started_by: "user-1")

      rfid = SecureRandom.uuid_v7
      emit(Frameworks::Events::RoleFamilyAdded,
        framework_id: @framework_id, role_family_id: rfid, name: "New Family")

      within_tenant do
        assert_nil FrameworkState::RoleFamily.find_by(role_family_id: rfid),
          "RoleFamily should NOT be created during draft"
      end
    end
  end

  context "FrameworkVersionPublished" do
    should "rebuild projection with draft events included" do
      # Use the full command handler so events go through the event store
      # (the rebuild reads from the stream)
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        handler.create_framework(@framework_id, "Test Framework")

        # Add a role family before draft
        existing_rfid = SecureRandom.uuid_v7
        handler.add_role_family(@framework_id, existing_rfid, "Engineering")

        # Start draft
        handler.start_draft(@framework_id, 1, "user-1")

        # Add a role family during draft — should be skipped by published projection
        draft_rfid = SecureRandom.uuid_v7
        handler.add_role_family(@framework_id, draft_rfid, "Design")

        assert_nil FrameworkState::RoleFamily.find_by(role_family_id: draft_rfid),
          "Draft family should NOT exist before publish"

        # Publish — triggers rebuild from event stream
        handler.publish_version(@framework_id, "user-1")

        fw = FrameworkState::Framework.find_by(framework_id: @framework_id)
        assert_equal 1, fw.current_published_version
        assert_not fw.draft_in_progress
        assert_nil fw.draft_version

        # Both pre-draft and draft families should exist after rebuild
        assert_not_nil FrameworkState::RoleFamily.find_by(role_family_id: existing_rfid)
        assert_not_nil FrameworkState::RoleFamily.find_by(role_family_id: draft_rfid),
          "Draft family should exist after publish rebuild"
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

  private

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
end
