# frozen_string_literal: true

require "test_helper"
require "rake"

class SeedFrameworkTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["frameworks:seed"].reenable
    create(:tenant, slug: "nullisland")
  end

  teardown do
    # Tests in this file use a real tenant + framework; wipe between runs.
    FrameworkState::Framework.destroy_all
    FrameworkExplorerGraph.delete_all
    Tenant.where(slug: "nullisland").destroy_all
  end

  should "publish v1 with departments and category thresholds from events" do
    Rake::Task["frameworks:seed"].invoke

    framework = FrameworkState::Framework.first
    assert_not_nil framework
    assert_equal 1, framework.current_published_version
    assert_not framework.draft_in_progress

    assert FrameworkState::RoleFamily.where.not(department: nil).exists?
    assert FrameworkState::CapabilityCategory.where.not(deficit_threshold: nil).exists?
  end

  should "keep the category thresholds through a rebuild, and in the explorer graph" do
    Rake::Task["frameworks:seed"].invoke
    tenant = Tenant.find_by!(slug: "nullisland")
    seeded = ActsAsTenant.with_tenant(tenant) { thresholds_by_category }
    assert_not_empty seeded.compact

    Frameworks::Projections::PublishedState.reset!(tenant: tenant)
    Projections::Replayer.replay(projection_class: Frameworks::Projections::PublishedState, tenant: tenant)

    ActsAsTenant.with_tenant(tenant) do
      assert_equal seeded, thresholds_by_category

      graph = FrameworkExplorerGraph.find(FrameworkState::Framework.first.framework_id)
      in_graph = graph.graph_data["capability_categories"].to_h { [ it["category_id"], it["deficit_threshold"]&.to_d ] }
      assert_equal seeded, in_graph
    end
  end

  private

  def thresholds_by_category
    FrameworkState::CapabilityCategory.pluck(:category_id, :deficit_threshold).to_h
  end
end
