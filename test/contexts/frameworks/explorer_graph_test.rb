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
      loaded = ActsAsTenant.with_tenant(@tenant) do
        Frameworks::ExplorerGraph.store(@framework_id, @graph)
        Frameworks::ExplorerGraph.load(@framework_id)
      end
      assert_equal @framework_id, loaded.framework_id
      assert_equal "Engineering Growth", loaded.name
      assert_equal [], loaded.role_families
      assert_equal [], loaded.capability_categories
    end

    should "upsert rather than create duplicate rows" do
      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::ExplorerGraph.store(@framework_id, @graph)
        Frameworks::ExplorerGraph.store(@framework_id, @graph)
      end

      assert_equal 1, FrameworkExplorerGraph.where(framework_id: @framework_id).count
    end

    should "scope rows by tenant so another tenant's load misses" do
      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::ExplorerGraph.store(@framework_id, @graph)
      end

      other_tenant = create(:tenant)
      loaded = ActsAsTenant.with_tenant(other_tenant) do
        Frameworks::ExplorerGraph.load(@framework_id)
      end
      assert_nil loaded, "load under a different tenant must not see the row"
    end
  end

  context ".load" do
    should "return nil when no row exists" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_nil Frameworks::ExplorerGraph.load(SecureRandom.uuid_v7)
      end
    end

    should "return nil on format_version mismatch (stale row)" do
      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::ExplorerGraph.store(@framework_id, @graph)
        FrameworkExplorerGraph.find_by(framework_id: @framework_id)
          .update_columns(format_version: Frameworks::ExplorerGraph::FORMAT_VERSION + 1)

        assert_nil Frameworks::ExplorerGraph.load(@framework_id)
      end
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
      graph, loaded = ActsAsTenant.with_tenant(@tenant) do
        g = Frameworks::ExplorerGraph.rebuild(@framework_id)
        [ g, Frameworks::ExplorerGraph.load(@framework_id) ]
      end

      assert_equal 1, graph.role_families.length
      assert_equal "Engineering", graph.role_families.first.name
      assert_equal graph.framework_id, loaded.framework_id
    end
  end

  context ".rebuild_all!" do
    setup do
      @other_tenant = create(:tenant)
      @other_framework_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@other_tenant) do
        Frameworks::CommandHandler.new.create_framework(@other_framework_id, "Other Framework")
      end
    end

    should "visit every framework across tenants even when called inside a tenant scope" do
      visited = []
      # Call from inside the first tenant's scope — acts_as_tenant's default
      # scope would silently filter the pluck to @tenant's frameworks only.
      # rebuild_all! must use without_tenant to see @other_tenant's too.
      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::ExplorerGraph.rebuild_all! do |fid, _i, _total|
          visited << fid
        end
      end

      assert_includes visited, @framework_id
      assert_includes visited, @other_framework_id
    end
  end
end
