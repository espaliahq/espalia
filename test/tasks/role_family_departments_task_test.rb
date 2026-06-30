# frozen_string_literal: true

require "test_helper"
require "rake"

# Backfill that promotes role-family department from a read-model-only column
# to an event-sourced fact (events:backfill_role_family_departments).
class RoleFamilyDepartmentsTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["events:backfill_role_family_departments"].reenable

    @tenant = create(:tenant)
    @framework_id = SecureRandom.uuid_v7
    @rf_id = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(@tenant) do
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      # Added WITHOUT a department — the legacy event shape.
      handler.add_role_family(@framework_id, @rf_id, "Engineering", description: "Builds things")
      handler.publish_version(@framework_id, "seed")
      # Simulate the old read-model-only department write.
      FrameworkState::RoleFamily
        .find_by!(role_family_id: @rf_id)
        .update_column(:department, "Product + Engineering")
    end
  end

  def aggregate_department
    dept = nil
    ActsAsTenant.with_tenant(@tenant) do
      Frameworks::Repository.new.with_framework(@framework_id) do |aggregate|
        dept = aggregate.role_families[@rf_id][:department]
      end
    end
    dept
  end

  def role_family_updated_count
    ActsAsTenant.with_tenant(@tenant) do
      Rails.configuration.event_store
        .read
        .stream(EventStreamNaming.framework_stream(@framework_id))
        .of_type([ Frameworks::Events::RoleFamilyUpdated ])
        .count
    end
  end

  should "emit a RoleFamilyUpdated carrying the read-model department" do
    assert_nil aggregate_department, "precondition: department not yet event-sourced"

    Rake::Task["events:backfill_role_family_departments"].invoke(@tenant.id)

    assert_equal "Product + Engineering", aggregate_department
    assert_equal 1, role_family_updated_count

    # The department-only update must leave name/description untouched.
    ActsAsTenant.with_tenant(@tenant) do
      record = FrameworkState::RoleFamily.find_by!(role_family_id: @rf_id)
      assert_equal "Engineering", record.name
      assert_equal "Builds things", record.description
    end
  end

  should "be idempotent on re-run" do
    Rake::Task["events:backfill_role_family_departments"].invoke(@tenant.id)
    Rake::Task["events:backfill_role_family_departments"].reenable
    Rake::Task["events:backfill_role_family_departments"].invoke(@tenant.id)

    assert_equal 1, role_family_updated_count, "re-run must not emit a second update"
  end
end
