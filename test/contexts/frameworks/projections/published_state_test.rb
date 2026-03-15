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
        role_id: rid, weight: 1.5, requirement_type: "flexible")

      within_tenant do
        rm = FrameworkState::CapabilityRoleBinding.find_by(binding_id: bid)
        assert_not_nil rm
        assert_equal 1.5, rm.weight.to_f
        assert_equal "flexible", rm.requirement_type
      end
    end
  end

  context "CapabilityRoleBindingRemoved" do
    should "destroy the binding read model" do
      bid = SecureRandom.uuid_v7
      emit(Frameworks::Events::CapabilityRoleBindingCreated,
        framework_id: @framework_id, binding_id: bid, capability_id: SecureRandom.uuid_v7,
        role_id: SecureRandom.uuid_v7, weight: 1.0, requirement_type: "must_have")
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
