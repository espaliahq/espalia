# frozen_string_literal: true

require "test_helper"
require "rake"

class MergeEngineeringCapabilitiesTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task_name = "frameworks:migrations:merge_engineering_capabilities"
    Rake::Task[@task_name].reenable

    @tenant = create(:tenant, slug: "test-merge")
    @framework_id = SecureRandom.uuid_v7
    @ids = build_minimal_framework_with_duplicates(@tenant, @framework_id)
  end

  teardown do
    ActsAsTenant.without_tenant do
      FrameworkState::Framework.where(framework_id: @framework_id).destroy_all
      FrameworkState::Collaborator.where(framework_id: @framework_id).delete_all
      FrameworkState::MigrationMapping.where(framework_id: @framework_id).delete_all
    end
    Tenant.where(slug: "test-merge").destroy_all
  end

  should "republish at v2 with merged bindings, archived duplicates, and an archived category" do
    Rake::Task[@task_name].invoke("test-merge")

    ActsAsTenant.with_tenant(@tenant) do
      framework = FrameworkState::Framework.find_by!(framework_id: @framework_id)
      assert_equal 2, framework.current_published_version
      assert_not framework.draft_in_progress

      @ids[:pairs].each do |pair|
        survivor_role_codes = binding_role_codes_for(pair[:survivor_cap_id])
        assert_equal %w[AE DE E EM], survivor_role_codes,
          "survivor #{pair[:capability_name].inspect} should be bound to all four engineering roles"

        archived_cap = FrameworkState::Capability.find_by!(capability_id: pair[:archive_cap_id])
        assert_equal "archived", archived_cap.status

        mapping = FrameworkState::MigrationMapping.find_by(from_stable_id: pair[:archive_cap_stable_id])
        assert_not_nil mapping, "mapping should exist for #{pair[:capability_name].inspect}"
        assert_equal pair[:survivor_cap_stable_id], mapping.to_stable_id
        assert_equal "same", mapping.mapping_type
      end

      archived_cat = FrameworkState::CapabilityCategory.find_by!(category_id: @ids[:cat8_id])
      assert_equal "archived", archived_cat.status
    end
  end

  should "be idempotent on a partial re-run after bindings already added" do
    survivor_cap_id = @ids[:pairs].first[:survivor_cap_id]
    ActsAsTenant.with_tenant(@tenant) do
      Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
        handler = Frameworks::CommandHandler.new
        handler.start_draft(@framework_id, 2, "manual-pre-bind")
        handler.create_capability_role_binding(
          @framework_id, SecureRandom.uuid_v7, survivor_cap_id, @ids[:de_role_id]
        )
        handler.publish_version(@framework_id, "manual-pre-bind")
      end
    end

    Rake::Task[@task_name].invoke("test-merge")

    ActsAsTenant.with_tenant(@tenant) do
      framework = FrameworkState::Framework.find_by!(framework_id: @framework_id)
      assert_equal 3, framework.current_published_version
      assert_equal %w[AE DE E EM], binding_role_codes_for(survivor_cap_id),
        "no duplicate bindings introduced on re-run"
    end
  end

  should "be a near-no-op on a full re-run with no duplicate MigrationMapping rows" do
    Rake::Task[@task_name].invoke("test-merge")
    Rake::Task[@task_name].reenable

    initial_mapping_count = ActsAsTenant.with_tenant(@tenant) { FrameworkState::MigrationMapping.count }
    assert_equal @ids[:pairs].size, initial_mapping_count, "first run should create one mapping per pair"

    Rake::Task[@task_name].invoke("test-merge")

    ActsAsTenant.with_tenant(@tenant) do
      assert_equal initial_mapping_count, FrameworkState::MigrationMapping.count,
        "second run should not duplicate migration mappings"

      @ids[:pairs].each do |pair|
        mappings = FrameworkState::MigrationMapping.where(from_stable_id: pair[:archive_cap_stable_id])
        assert_equal 1, mappings.size,
          "expected exactly one mapping per archived stable_id, even after re-run"
      end
    end
  end

  should "refuse when a draft is already in progress" do
    ActsAsTenant.with_tenant(@tenant) do
      Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
        Frameworks::CommandHandler.new.start_draft(@framework_id, 2, "someone-else")
      end
    end

    err = assert_raises(SystemExit) { Rake::Task[@task_name].invoke("test-merge") }
    assert_equal 1, err.status
  end

  private

  CAPABILITY_MERGES = [
    [ "Technical Expertise", "Technical Expertise: Cloud Architecture & Infrastructure" ],
    [ "Role Specific",       "System Design & Architecture" ],
    [ "Role Specific",       "Quality First Mindset" ],
    [ "Role Specific",       "DevSecOps (Development, Security & Operations) Mindset" ]
  ].freeze

  def binding_role_codes_for(capability_id)
    FrameworkState::CapabilityRoleBinding
      .where(capability_id: capability_id)
      .joins("INNER JOIN framework_roles ON framework_roles.role_id = framework_capability_role_bindings.role_id")
      .pluck("framework_roles.code")
      .sort
  end

  # Builds a minimal framework that mirrors the full me&u duplicate
  # shape — Cat 8 "Engineering Capabilities" + Cat 10/11 survivors —
  # without seeding every category, role, level, expectation, and
  # illustration.
  def build_minimal_framework_with_duplicates(tenant, framework_id) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
    ActsAsTenant.with_tenant(tenant) do
      handler = Frameworks::CommandHandler.new
      ids = {}

      Rails.configuration.event_store.with_metadata(tenant_id: tenant.id) do
        handler.create_framework(framework_id, "Test Framework")

        eng_rfid = SecureRandom.uuid_v7
        handler.add_role_family(framework_id, eng_rfid, "Software Engineering")
        ids[:e_role_id]  = SecureRandom.uuid_v7
        ids[:em_role_id] = SecureRandom.uuid_v7
        handler.add_role(framework_id, ids[:e_role_id],  eng_rfid, "Software Engineer", "E",  "ic")
        handler.add_role(framework_id, ids[:em_role_id], eng_rfid, "Engineering Manager", "EM", "management")

        data_rfid = SecureRandom.uuid_v7
        handler.add_role_family(framework_id, data_rfid, "Data")
        ids[:de_role_id] = SecureRandom.uuid_v7
        ids[:ae_role_id] = SecureRandom.uuid_v7
        handler.add_role(framework_id, ids[:de_role_id], data_rfid, "Data Engineer", "DE", "ic")
        handler.add_role(framework_id, ids[:ae_role_id], data_rfid, "Analytics Engineer", "AE", "ic")

        # Categories: Cat 8 (to be archived) + Cat 10 + Cat 11 (survivor homes)
        ids[:cat8_id] = SecureRandom.uuid_v7
        handler.add_capability_category(framework_id, ids[:cat8_id], "Engineering Capabilities", ordinal: 1)
        target_category_ids = CAPABILITY_MERGES.map { |cat, _| cat }.uniq.to_h do |name|
          cat_id = SecureRandom.uuid_v7
          handler.add_capability_category(framework_id, cat_id, name, ordinal: 2)
          [ name, cat_id ]
        end

        ids[:pairs] = CAPABILITY_MERGES.map do |target_category, capability_name|
          archive_cap_id         = SecureRandom.uuid_v7
          archive_cap_stable_id  = SecureRandom.uuid_v7
          survivor_cap_id        = SecureRandom.uuid_v7
          survivor_cap_stable_id = SecureRandom.uuid_v7

          handler.add_capability(framework_id, archive_cap_id, archive_cap_stable_id,
            ids[:cat8_id], capability_name)
          handler.add_capability(framework_id, survivor_cap_id, survivor_cap_stable_id,
            target_category_ids.fetch(target_category), capability_name)

          # Duplicate shape: Cat 8 cap → DE only; survivor → E + EM
          handler.create_capability_role_binding(framework_id, SecureRandom.uuid_v7, archive_cap_id, ids[:de_role_id])
          handler.create_capability_role_binding(framework_id, SecureRandom.uuid_v7, survivor_cap_id, ids[:e_role_id])
          handler.create_capability_role_binding(framework_id, SecureRandom.uuid_v7, survivor_cap_id, ids[:em_role_id])

          {
            capability_name: capability_name,
            archive_cap_id: archive_cap_id,
            archive_cap_stable_id: archive_cap_stable_id,
            survivor_cap_id: survivor_cap_id,
            survivor_cap_stable_id: survivor_cap_stable_id
          }
        end

        handler.publish_version(framework_id, "test-setup")
      end

      ids
    end
  end
end
