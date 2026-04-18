# frozen_string_literal: true

require "test_helper"

class Frameworks::ExplorerGraphTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @framework_id = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(@tenant) do
      Frameworks::CommandHandler.new.create_framework(@framework_id, "Engineering Growth")
    end

    aggregate = Frameworks::Aggregate.new
    aggregate.create(@framework_id, "Engineering Growth")
    @graph = Frameworks::ExplorerGraphBuilder.new(aggregate).build
  end

  context ".store + .load round-trip" do
    should "persist and deserialize identically" do
      Frameworks::ExplorerGraph.store(@framework_id, @graph)

      loaded = Frameworks::ExplorerGraph.load(@framework_id)
      assert_equal @framework_id, loaded.framework_id
      assert_equal "Engineering Growth", loaded.name
      assert_equal [], loaded.role_families
      assert_equal [], loaded.capability_categories
    end

    should "upsert rather than create duplicate rows" do
      Frameworks::ExplorerGraph.store(@framework_id, @graph)
      Frameworks::ExplorerGraph.store(@framework_id, @graph)

      assert_equal 1, FrameworkExplorerGraph.where(framework_id: @framework_id).count
    end
  end

  context ".load" do
    should "return nil when no row exists" do
      assert_nil Frameworks::ExplorerGraph.load(SecureRandom.uuid_v7)
    end

    should "return nil on format_version mismatch (stale row)" do
      Frameworks::ExplorerGraph.store(@framework_id, @graph)
      FrameworkExplorerGraph.find_by(framework_id: @framework_id)
        .update_columns(format_version: Frameworks::ExplorerGraph::FORMAT_VERSION + 1)

      assert_nil Frameworks::ExplorerGraph.load(@framework_id)
    end
  end

  context ".rebuild" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        rfid = SecureRandom.uuid_v7
        handler.add_role_family(@framework_id, rfid, "Engineering")
      end
    end

    should "load the aggregate, rebuild, store, and return the graph" do
      graph = ActsAsTenant.with_tenant(@tenant) do
        Frameworks::ExplorerGraph.rebuild(@framework_id)
      end

      assert_equal 1, graph.role_families.length
      assert_equal "Engineering", graph.role_families.first.name
      assert_equal graph.framework_id, Frameworks::ExplorerGraph.load(@framework_id).framework_id
    end
  end
end
