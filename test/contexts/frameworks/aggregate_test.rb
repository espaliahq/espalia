# frozen_string_literal: true

require "test_helper"

class Frameworks::AggregateTest < ActiveSupport::TestCase
  setup do
    @aggregate = Frameworks::Aggregate.new
    @framework_id = SecureRandom.uuid_v7
    @aggregate.create(@framework_id, "Engineering Growth")
  end

  # ── Creation ──

  context "#create" do
    should "apply FrameworkCreated and bootstrap v1 DraftVersionStarted" do
      aggregate = Frameworks::Aggregate.new
      fid = SecureRandom.uuid_v7
      aggregate.create(fid, "Engineering Growth")

      events = aggregate.unpublished_events.to_a
      assert_equal 2, events.length
      assert_kind_of Frameworks::Events::FrameworkCreated, events[0]
      assert_equal fid, events[0].data[:framework_id]
      assert_equal "Engineering Growth", events[0].data[:name]
      assert_kind_of Frameworks::Events::DraftVersionStarted, events[1]
      assert_equal 1, events[1].data[:target_version]
      assert_equal "system", events[1].data[:started_by]
    end

    should "raise if framework already created" do
      assert_raises(RuntimeError, /already created/) do
        @aggregate.create(@framework_id, "Duplicate")
      end
    end
  end

  # ── Role Families ──

  context "#add_role_family" do
    should "apply RoleFamilyAdded event" do
      rfid = SecureRandom.uuid_v7
      @aggregate.add_role_family(@framework_id, rfid, "Engineering", description: "Tech roles")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::RoleFamilyAdded, event
      assert_equal rfid, event.data[:role_family_id]
      assert_equal "Engineering", event.data[:name]
      assert_equal "Tech roles", event.data[:description]
    end

    should "raise if role family already exists" do
      rfid = SecureRandom.uuid_v7
      @aggregate.add_role_family(@framework_id, rfid, "Engineering")

      assert_raises(RuntimeError, /already exists/) do
        @aggregate.add_role_family(@framework_id, rfid, "Duplicate")
      end
    end

    should "raise if framework not created" do
      aggregate = Frameworks::Aggregate.new
      assert_raises(RuntimeError, /not yet created/) do
        aggregate.add_role_family("fid", "rfid", "Test")
      end
    end
  end

  context "#update_role_family" do
    should "apply RoleFamilyUpdated event" do
      rfid = SecureRandom.uuid_v7
      @aggregate.add_role_family(@framework_id, rfid, "Engineering")
      @aggregate.update_role_family(@framework_id, rfid, name: "Software Engineering")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::RoleFamilyUpdated, event
      assert_equal "Software Engineering", event.data[:name]
    end

    should "raise if role family not found" do
      assert_raises(RuntimeError, /not found/) do
        @aggregate.update_role_family(@framework_id, "nonexistent", name: "X")
      end
    end
  end

  # ── Roles ──

  context "#add_role" do
    setup do
      @rfid = SecureRandom.uuid_v7
      @aggregate.add_role_family(@framework_id, @rfid, "Engineering")
    end

    should "apply RoleAdded event" do
      rid = SecureRandom.uuid_v7
      @aggregate.add_role(@framework_id, rid, @rfid, "Software Engineer", "E", "ic")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::RoleAdded, event
      assert_equal rid, event.data[:role_id]
      assert_equal "Software Engineer", event.data[:name]
      assert_equal "E", event.data[:code]
      assert_equal "ic", event.data[:track]
    end

    should "raise if role family not found" do
      assert_raises(RuntimeError, /not found/) do
        @aggregate.add_role(@framework_id, SecureRandom.uuid_v7, "nonexistent", "X", "X", "ic")
      end
    end

    should "raise if role already exists" do
      rid = SecureRandom.uuid_v7
      @aggregate.add_role(@framework_id, rid, @rfid, "Engineer", "E", "ic")

      assert_raises(RuntimeError, /already exists/) do
        @aggregate.add_role(@framework_id, rid, @rfid, "Duplicate", "D", "ic")
      end
    end
  end

  # ── Levels ──

  context "#add_level" do
    setup do
      @rfid = SecureRandom.uuid_v7
      @rid = SecureRandom.uuid_v7
      @aggregate.add_role_family(@framework_id, @rfid, "Engineering")
      @aggregate.add_role(@framework_id, @rid, @rfid, "Software Engineer", "E", "ic")
    end

    should "apply LevelAdded event" do
      lid = SecureRandom.uuid_v7
      @aggregate.add_level(@framework_id, lid, @rid, 1, "Software Engineer I", "E1", is_entry: true)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::LevelAdded, event
      assert_equal lid, event.data[:level_id]
      assert_equal 1, event.data[:ordinal]
      assert_equal "Software Engineer I", event.data[:title]
      assert_equal "E1", event.data[:code]
      assert_equal true, event.data[:is_entry]
    end

    should "raise if role not found" do
      assert_raises(RuntimeError, /not found/) do
        @aggregate.add_level(@framework_id, SecureRandom.uuid_v7, "nonexistent", 1, "X", "X1")
      end
    end
  end

  # ── Capability Categories ──

  context "#add_capability_category" do
    should "apply CapabilityCategoryAdded event" do
      cid = SecureRandom.uuid_v7
      @aggregate.add_capability_category(@framework_id, cid, "Thinking & Delivery", description: "How we think", ordinal: 1)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::CapabilityCategoryAdded, event
      assert_equal cid, event.data[:category_id]
      assert_equal "Thinking & Delivery", event.data[:name]
      assert_equal 1, event.data[:ordinal]
    end

    should "raise if category already exists" do
      cid = SecureRandom.uuid_v7
      @aggregate.add_capability_category(@framework_id, cid, "Category")

      assert_raises(RuntimeError, /already exists/) do
        @aggregate.add_capability_category(@framework_id, cid, "Duplicate")
      end
    end
  end

  # ── Capabilities ──

  context "#add_capability" do
    setup do
      @cat_id = SecureRandom.uuid_v7
      @aggregate.add_capability_category(@framework_id, @cat_id, "Thinking")
    end

    should "apply CapabilityAdded event" do
      cap_id = SecureRandom.uuid_v7
      stable_id = SecureRandom.uuid_v7
      @aggregate.add_capability(@framework_id, cap_id, stable_id, @cat_id, "Strategic Thinking", description: "Long-term thinking")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::CapabilityAdded, event
      assert_equal cap_id, event.data[:capability_id]
      assert_equal stable_id, event.data[:stable_id]
      assert_equal "Strategic Thinking", event.data[:name]
    end

    should "raise if category not found" do
      assert_raises(RuntimeError, /not found/) do
        @aggregate.add_capability(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, "nonexistent", "X")
      end
    end
  end

  context "#archive_capability" do
    setup do
      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @aggregate.add_capability_category(@framework_id, @cat_id, "Thinking")
      @aggregate.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Old Cap")
    end

    should "apply CapabilityArchived event" do
      @aggregate.archive_capability(@framework_id, @cap_id, reason: "Superseded")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::CapabilityArchived, event
      assert_equal @cap_id, event.data[:capability_id]
      assert_equal "Superseded", event.data[:reason]
    end

    should "raise if already archived" do
      @aggregate.archive_capability(@framework_id, @cap_id, reason: "Superseded")

      assert_raises(RuntimeError, /already archived/) do
        @aggregate.archive_capability(@framework_id, @cap_id, reason: "Again")
      end
    end
  end

  # ── Capability Role Bindings ──

  context "#create_capability_role_binding" do
    setup do
      @rfid = SecureRandom.uuid_v7
      @rid = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @aggregate.add_role_family(@framework_id, @rfid, "Engineering")
      @aggregate.add_role(@framework_id, @rid, @rfid, "Engineer", "E", "ic")
      @aggregate.add_capability_category(@framework_id, @cat_id, "Thinking")
      @aggregate.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Strategic Thinking")
    end

    should "apply CapabilityRoleBindingCreated event" do
      bid = SecureRandom.uuid_v7
      @aggregate.create_capability_role_binding(@framework_id, bid, @cap_id, @rid, weight: 1.5, individual_tolerance: 2.0)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::CapabilityRoleBindingCreated, event
      assert_equal bid, event.data[:binding_id]
      assert_equal 1.5, event.data[:weight]
      assert_equal 2.0, event.data[:individual_tolerance]
    end

    should "raise if capability not found" do
      assert_raises(RuntimeError, /not found/) do
        @aggregate.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, "nonexistent", @rid)
      end
    end

    should "raise if role not found" do
      assert_raises(RuntimeError, /not found/) do
        @aggregate.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_id, "nonexistent")
      end
    end
  end

  context "#remove_capability_role_binding" do
    should "apply CapabilityRoleBindingRemoved event" do
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      bid = SecureRandom.uuid_v7

      @aggregate.add_role_family(@framework_id, rfid, "Eng")
      @aggregate.add_role(@framework_id, rid, rfid, "Engineer", "E", "ic")
      @aggregate.add_capability_category(@framework_id, cat_id, "Thinking")
      @aggregate.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Cap")
      @aggregate.create_capability_role_binding(@framework_id, bid, cap_id, rid)
      @aggregate.remove_capability_role_binding(@framework_id, bid)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::CapabilityRoleBindingRemoved, event
      assert_equal bid, event.data[:binding_id]
    end
  end

  # ── Behavioural Expectations ──

  context "#set_behavioural_expectation" do
    setup do
      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @aggregate.add_capability_category(@framework_id, @cat_id, "Thinking")
      @aggregate.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Strategic Thinking")
    end

    should "apply BehaviouralExpectationSet event" do
      eid = SecureRandom.uuid_v7
      sid = SecureRandom.uuid_v7
      @aggregate.set_behavioural_expectation(@framework_id, eid, sid, @cap_id, 1, "Asks questions to understand problems.")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::BehaviouralExpectationSet, event
      assert_equal eid, event.data[:expectation_id]
      assert_equal sid, event.data[:stable_id]
      assert_equal 1, event.data[:level_ordinal]
      assert_equal "Asks questions to understand problems.", event.data[:description]
    end

    should "raise if capability not found" do
      assert_raises(RuntimeError, /not found/) do
        @aggregate.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, "nonexistent", 1, "X")
      end
    end
  end

  context "#update_behavioural_expectation" do
    should "apply BehaviouralExpectationUpdated event" do
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      eid = SecureRandom.uuid_v7

      @aggregate.add_capability_category(@framework_id, cat_id, "Thinking")
      @aggregate.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Cap")
      @aggregate.set_behavioural_expectation(@framework_id, eid, SecureRandom.uuid_v7, cap_id, 1, "Original")
      @aggregate.update_behavioural_expectation(@framework_id, eid, "Updated description", rationale: "Clearer wording")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::BehaviouralExpectationUpdated, event
      assert_equal "Updated description", event.data[:new_description]
      assert_equal "Clearer wording", event.data[:rationale]
    end
  end

  # ── Role Illustrations ──

  context "#add_role_illustration" do
    setup do
      @rfid = SecureRandom.uuid_v7
      @rid = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @eid = SecureRandom.uuid_v7

      @aggregate.add_role_family(@framework_id, @rfid, "Engineering")
      @aggregate.add_role(@framework_id, @rid, @rfid, "Engineer", "E", "ic")
      @aggregate.add_capability_category(@framework_id, @cat_id, "Thinking")
      @aggregate.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Cap")
      @aggregate.set_behavioural_expectation(@framework_id, @eid, SecureRandom.uuid_v7, @cap_id, 1, "Asks questions")
    end

    should "apply RoleIllustrationAdded event" do
      iid = SecureRandom.uuid_v7
      sid = SecureRandom.uuid_v7
      @aggregate.add_role_illustration(@framework_id, iid, sid, @eid, @rid, 1, "Seeks guidance from tech lead")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::RoleIllustrationAdded, event
      assert_equal iid, event.data[:illustration_id]
      assert_equal sid, event.data[:stable_id]
      assert_equal @eid, event.data[:expectation_id]
      assert_equal @rid, event.data[:role_id]
      assert_equal 1, event.data[:ordinal]
    end

    should "raise if expectation not found" do
      assert_raises(RuntimeError, /not found/) do
        @aggregate.add_role_illustration(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, "nonexistent", @rid, 1, "X")
      end
    end

    should "raise if role not found" do
      assert_raises(RuntimeError, /not found/) do
        @aggregate.add_role_illustration(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @eid, "nonexistent", 1, "X")
      end
    end
  end

  context "#remove_role_illustration" do
    should "apply RoleIllustrationRemoved event" do
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      eid = SecureRandom.uuid_v7
      iid = SecureRandom.uuid_v7

      @aggregate.add_role_family(@framework_id, rfid, "Eng")
      @aggregate.add_role(@framework_id, rid, rfid, "Engineer", "E", "ic")
      @aggregate.add_capability_category(@framework_id, cat_id, "Thinking")
      @aggregate.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Cap")
      @aggregate.set_behavioural_expectation(@framework_id, eid, SecureRandom.uuid_v7, cap_id, 1, "Asks questions")
      @aggregate.add_role_illustration(@framework_id, iid, SecureRandom.uuid_v7, eid, rid, 1, "Example")
      @aggregate.remove_role_illustration(@framework_id, iid, reason: "Outdated")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::RoleIllustrationRemoved, event
      assert_equal iid, event.data[:illustration_id]
    end
  end

  # ── Versioning ──

  context "#create bootstraps v1 draft" do
    should "emit FrameworkCreated then DraftVersionStarted(target_version: 1)" do
      fresh = Frameworks::Aggregate.new
      fid = SecureRandom.uuid_v7
      fresh.create(fid, "Bootstrap test")

      events = fresh.unpublished_events.to_a
      assert_equal 2, events.length
      assert_kind_of Frameworks::Events::FrameworkCreated, events[0]
      assert_kind_of Frameworks::Events::DraftVersionStarted, events[1]
      assert_equal 1, events[1].data[:target_version]
      assert_equal "system", events[1].data[:started_by]
    end

    should "allow structural commands immediately after create" do
      fresh = Frameworks::Aggregate.new
      fid = SecureRandom.uuid_v7
      fresh.create(fid, "Bootstrap test")

      # Structural commands require a draft — the bootstrap draft makes them available
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      fresh.add_role_family(fid, rfid, "RF")
      fresh.add_role(fid, rid, rfid, "R", "R", "ic")
      fresh.add_capability_category(fid, cat_id, "C")
      assert_nothing_raised do
        fresh.add_capability(fid, cap_id, SecureRandom.uuid_v7, cat_id, "Cap")
      end
    end
  end

  context "#start_draft" do
    setup do
      # Fresh aggregate that has published v1 (closing the bootstrap draft)
      # so we can test explicit start_draft for subsequent versions.
      @fresh = Frameworks::Aggregate.new
      @fresh.create(@framework_id, "Test")
      @fresh.publish_version(@framework_id, "user-1")
    end

    should "apply DraftVersionStarted event for v2" do
      @fresh.start_draft(@framework_id, 2, "user-1")

      event = @fresh.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::DraftVersionStarted, event
      assert_equal @framework_id, event.data[:framework_id]
      assert_equal 2, event.data[:target_version]
      assert_equal "user-1", event.data[:started_by]
    end

    should "raise if draft already in progress" do
      @fresh.start_draft(@framework_id, 2, "user-1")

      assert_raises(RuntimeError, /Draft already in progress/) do
        @fresh.start_draft(@framework_id, 3, "user-1")
      end
    end

    should "raise if target version not greater than current" do
      assert_raises(RuntimeError, /greater than current/) do
        @fresh.start_draft(@framework_id, 1, "user-1")
      end
    end

    should "raise if draft already in progress on a fresh bootstrap framework" do
      freshly_bootstrapped = Frameworks::Aggregate.new
      fid = SecureRandom.uuid_v7
      freshly_bootstrapped.create(fid, "Boot")
      # The bootstrap draft is v1 — calling start_draft again should error
      assert_raises(RuntimeError, /Draft already in progress/) do
        freshly_bootstrapped.start_draft(fid, 2, "user-1")
      end
    end
  end

  context "#publish_version" do
    should "apply FrameworkVersionPublished for bootstrap v1" do
      # Global setup already did create (which bootstraps v1 draft)
      @aggregate.publish_version(@framework_id, "user-1")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::FrameworkVersionPublished, event
      assert_equal @framework_id, event.data[:framework_id]
      assert_equal 1, event.data[:version]
      assert_equal "user-1", event.data[:published_by]
    end

    should "raise if no draft in progress" do
      fresh = Frameworks::Aggregate.new
      fresh.create(@framework_id, "Test")
      fresh.publish_version(@framework_id, "user-1") # close bootstrap

      assert_raises(RuntimeError, /No draft in progress/) do
        fresh.publish_version(@framework_id, "user-1")
      end
    end

    should "allow starting a new draft after publishing" do
      fresh = Frameworks::Aggregate.new
      fresh.create(@framework_id, "Test")
      fresh.publish_version(@framework_id, "user-1")
      fresh.start_draft(@framework_id, 2, "user-1")

      event = fresh.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::DraftVersionStarted, event
      assert_equal 2, event.data[:target_version]
    end
  end

  context "#define_migration_mapping" do
    should "apply MigrationMappingDefined event inside the bootstrap draft" do
      mid = SecureRandom.uuid_v7
      from_sid = SecureRandom.uuid_v7
      to_sid = SecureRandom.uuid_v7
      @aggregate.define_migration_mapping(@framework_id, mid, from_sid, to_sid, "evolved",
                                          requires_reassessment: true, reason: "Scope broadened")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::MigrationMappingDefined, event
      assert_equal mid, event.data[:mapping_id]
      assert_equal from_sid, event.data[:from_stable_id]
      assert_equal to_sid, event.data[:to_stable_id]
      assert_equal "evolved", event.data[:mapping_type]
      assert event.data[:requires_reassessment]
      assert_equal "Scope broadened", event.data[:reason]
    end

    should "raise if no draft in progress" do
      fresh = Frameworks::Aggregate.new
      fresh.create(@framework_id, "Test")
      fresh.publish_version(@framework_id, "user-1") # close bootstrap

      assert_raises(RuntimeError, /No draft in progress/) do
        fresh.define_migration_mapping(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                       SecureRandom.uuid_v7, "same")
      end
    end
  end

  # ── Shape-changing command draft guard ──

  context "shape-changing command draft guard" do
    setup do
      @fresh = Frameworks::Aggregate.new
      @fresh.create(@framework_id, "Test")
      @rfid = SecureRandom.uuid_v7
      @rid = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @fresh.add_role_family(@framework_id, @rfid, "RF")
      @fresh.add_role(@framework_id, @rid, @rfid, "R", "R", "ic")
      @fresh.add_capability_category(@framework_id, @cat_id, "Cat")
      @fresh.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Cap")
      @fresh.publish_version(@framework_id, "user-1") # close bootstrap, no draft
    end

    should "add_level raises outside a draft" do
      assert_raises(RuntimeError, /No draft in progress/) do
        @fresh.add_level(@framework_id, SecureRandom.uuid_v7, @rid, 1, "L1", "R1")
      end
    end

    should "add_capability raises outside a draft" do
      assert_raises(RuntimeError, /No draft in progress/) do
        @fresh.add_capability(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cat_id, "New")
      end
    end

    should "archive_capability raises outside a draft" do
      assert_raises(RuntimeError, /No draft in progress/) do
        @fresh.archive_capability(@framework_id, @cap_id, reason: "test")
      end
    end

    should "create_capability_role_binding raises outside a draft" do
      assert_raises(RuntimeError, /No draft in progress/) do
        @fresh.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_id, @rid)
      end
    end

    should "remove_capability_role_binding raises outside a draft" do
      assert_raises(RuntimeError, /No draft in progress/) do
        @fresh.remove_capability_role_binding(@framework_id, SecureRandom.uuid_v7)
      end
    end

    should "set_behavioural_expectation raises outside a draft" do
      assert_raises(RuntimeError, /No draft in progress/) do
        @fresh.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                           @cap_id, 1, "desc")
      end
    end

    should "change_level_ordinal raises outside a draft" do
      # No level exists at this point in setup; guard fires before the lookup
      assert_raises(RuntimeError, /No draft in progress/) do
        @fresh.change_level_ordinal(@framework_id, SecureRandom.uuid_v7, 5, reason: "test")
      end
    end
  end

  # ── Editorial commands outside a draft ──

  context "editorial commands outside a draft" do
    setup do
      @fresh = Frameworks::Aggregate.new
      @fresh.create(@framework_id, "Test")
      @rfid = SecureRandom.uuid_v7
      @rid = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @eid = SecureRandom.uuid_v7
      @lid = SecureRandom.uuid_v7
      @fresh.add_role_family(@framework_id, @rfid, "RF")
      @fresh.add_role(@framework_id, @rid, @rfid, "R", "R", "ic")
      @fresh.add_level(@framework_id, @lid, @rid, 1, "L1", "R1")
      @fresh.add_capability_category(@framework_id, @cat_id, "Cat")
      @fresh.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Cap")
      @fresh.set_behavioural_expectation(@framework_id, @eid, SecureRandom.uuid_v7, @cap_id, 1, "Exp")
      @fresh.publish_version(@framework_id, "user-1") # close bootstrap, no draft
    end

    should "update_role_family succeeds" do
      assert_nothing_raised do
        @fresh.update_role_family(@framework_id, @rfid, name: "Updated")
      end
    end

    should "update_role succeeds" do
      assert_nothing_raised do
        @fresh.update_role(@framework_id, @rid, name: "Updated")
      end
    end

    should "update_level_details succeeds" do
      assert_nothing_raised do
        @fresh.update_level_details(@framework_id, @lid, title: "New Title", code: "NC")
      end
    end

    should "update_capability_category succeeds" do
      assert_nothing_raised do
        @fresh.update_capability_category(@framework_id, @cat_id, name: "Updated")
      end
    end

    should "update_behavioural_expectation succeeds" do
      assert_nothing_raised do
        @fresh.update_behavioural_expectation(@framework_id, @eid, "Updated text", rationale: "clarity")
      end
    end

    should "add_role_illustration succeeds" do
      assert_nothing_raised do
        @fresh.add_role_illustration(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                     @eid, @rid, 1, "Example")
      end
    end
  end

  # ── Level command split ──

  context "#update_level_details" do
    setup do
      @rfid = SecureRandom.uuid_v7
      @rid = SecureRandom.uuid_v7
      @lid = SecureRandom.uuid_v7
      @aggregate.add_role_family(@framework_id, @rfid, "RF")
      @aggregate.add_role(@framework_id, @rid, @rfid, "R", "R", "ic")
      @aggregate.add_level(@framework_id, @lid, @rid, 1, "Original", "R1", is_entry: true)
    end

    should "apply LevelUpdated without ordinal" do
      @aggregate.update_level_details(@framework_id, @lid, title: "New Title", code: "NC", is_entry: false)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::LevelUpdated, event
      assert_equal "New Title", event.data[:title]
      assert_equal "NC", event.data[:code]
      assert_equal false, event.data[:is_entry]
      assert_not event.data.key?(:ordinal)
    end

    should "raise if level not found" do
      assert_raises(RuntimeError, /not found/) do
        @aggregate.update_level_details(@framework_id, "nonexistent", title: "X")
      end
    end
  end

  context "#change_level_ordinal" do
    setup do
      @rfid = SecureRandom.uuid_v7
      @rid = SecureRandom.uuid_v7
      @lid = SecureRandom.uuid_v7
      @aggregate.add_role_family(@framework_id, @rfid, "RF")
      @aggregate.add_role(@framework_id, @rid, @rfid, "R", "R", "ic")
      @aggregate.add_level(@framework_id, @lid, @rid, 1, "L1", "R1")
    end

    should "apply LevelOrdinalChanged event inside a draft" do
      @aggregate.change_level_ordinal(@framework_id, @lid, 5, reason: "Renumbered")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of Frameworks::Events::LevelOrdinalChanged, event
      assert_equal @lid, event.data[:level_id]
      assert_equal 5, event.data[:new_ordinal]
      assert_equal 1, event.data[:previous_ordinal]
      assert_equal "Renumbered", event.data[:reason]
    end

    should "no-op if new_ordinal equals previous_ordinal" do
      before_count = @aggregate.unpublished_events.to_a.length
      @aggregate.change_level_ordinal(@framework_id, @lid, 1, reason: "no change")
      assert_equal before_count, @aggregate.unpublished_events.to_a.length
    end

    should "raise if level not found" do
      assert_raises(RuntimeError, /not found/) do
        @aggregate.change_level_ordinal(@framework_id, "nonexistent", 5, reason: "test")
      end
    end
  end

  # ── Migration mapping enforcement at publish ──

  context "#publish_version migration mapping enforcement" do
    should "raise when an archived capability lacks a migration mapping" do
      fresh = Frameworks::Aggregate.new
      fresh.create(@framework_id, "Test")
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      stable_id = SecureRandom.uuid_v7
      fresh.add_capability_category(@framework_id, cat_id, "Cat")
      fresh.add_capability(@framework_id, cap_id, stable_id, cat_id, "Cap")
      fresh.publish_version(@framework_id, "user-1") # v1 published

      fresh.start_draft(@framework_id, 2, "user-1")
      fresh.archive_capability(@framework_id, cap_id, reason: "Superseded")

      assert_raises(RuntimeError, /lack migration mappings/) do
        fresh.publish_version(@framework_id, "user-1")
      end
    end

    should "succeed when archived capability has a mapping" do
      fresh = Frameworks::Aggregate.new
      fresh.create(@framework_id, "Test")
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      stable_id = SecureRandom.uuid_v7
      fresh.add_capability_category(@framework_id, cat_id, "Cat")
      fresh.add_capability(@framework_id, cap_id, stable_id, cat_id, "Cap")
      fresh.publish_version(@framework_id, "user-1")

      fresh.start_draft(@framework_id, 2, "user-1")
      fresh.archive_capability(@framework_id, cap_id, reason: "Superseded")
      fresh.define_migration_mapping(@framework_id, SecureRandom.uuid_v7, stable_id, nil, "archived",
                                     reason: "Retired")

      assert_nothing_raised do
        fresh.publish_version(@framework_id, "user-1")
      end
    end

    should "not require a mapping for capabilities added and archived in the same draft" do
      fresh = Frameworks::Aggregate.new
      fresh.create(@framework_id, "Test")
      cat_id = SecureRandom.uuid_v7
      fresh.add_capability_category(@framework_id, cat_id, "Cat")
      fresh.publish_version(@framework_id, "user-1")

      fresh.start_draft(@framework_id, 2, "user-1")
      cap_id = SecureRandom.uuid_v7
      fresh.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Transient")
      fresh.archive_capability(@framework_id, cap_id, reason: "Never mind")

      assert_nothing_raised do
        fresh.publish_version(@framework_id, "user-1")
      end
    end
  end
end
