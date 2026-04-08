# frozen_string_literal: true

require "test_helper"
require "rake"

class SeedFrameworkTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["frameworks:seed_meandu"].reenable
    create(:tenant, slug: "meandu")
  end

  teardown do
    # Tests in this file use a real tenant + framework; wipe between runs.
    FrameworkState::Framework.destroy_all
    Tenant.where(slug: "meandu").destroy_all
  end

  should "publish the framework to version 1" do
    Rake::Task["frameworks:seed_meandu"].invoke

    framework = FrameworkState::Framework.first
    assert_not_nil framework
    assert_equal 1, framework.current_published_version
    assert_not framework.draft_in_progress
  end

  should "apply deferred department updates after publish" do
    Rake::Task["frameworks:seed_meandu"].invoke

    # Proof that the deferred update ran post-publish — the read-model row
    # exists (rebuild replayed the RoleFamilyAdded events) AND the inline
    # department mutation from the rake task found it.
    assert FrameworkState::RoleFamily.where.not(department: nil).exists?
  end

  should "apply deferred capability category deficit_threshold updates after publish" do
    Rake::Task["frameworks:seed_meandu"].invoke

    # At least one seeded category (Finance Core) has a deficit_threshold.
    assert FrameworkState::CapabilityCategory.where.not(deficit_threshold: nil).exists?
  end
end
