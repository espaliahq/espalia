# frozen_string_literal: true

require "test_helper"

# Exercises the snapshot-on-write extension of Frameworks::Repository —
# verifying that framework events and the ExplorerGraph row land (or don't)
# together, never diverging.
class Frameworks::RepositoryTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
  end

  context "#with_framework writes snapshot alongside events" do
    should "persist ExplorerGraph after a successful command block" do
      framework_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::Repository.new.with_framework(framework_id) do |framework|
          framework.create(framework_id, "Engineering Growth")
          framework.add_role_family(framework_id, SecureRandom.uuid_v7, "Engineering")
        end
      end

      row = FrameworkExplorerGraph.find_by(framework_id: framework_id)
      assert row, "expected an ExplorerGraph row after the command block"
      assert_equal Frameworks::ExplorerGraph::FORMAT_VERSION, row.format_version

      graph = Frameworks::ExplorerGraph.load(framework_id)
      assert_equal "Engineering Growth", graph.name
      assert_equal 1, graph.role_families.length
    end

    should "update the snapshot on every subsequent command" do
      framework_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::CommandHandler.new.create_framework(framework_id, "Engineering Growth")
        first_snapshot_at = FrameworkExplorerGraph.find_by(framework_id: framework_id).updated_at

        sleep 0.01 # ensure timestamp resolution
        Frameworks::CommandHandler.new.add_role_family(
          framework_id, SecureRandom.uuid_v7, "Engineering"
        )

        row = FrameworkExplorerGraph.find_by(framework_id: framework_id)
        assert_operator row.updated_at, :>, first_snapshot_at
        graph = Frameworks::ExplorerGraph.load(framework_id)
        assert_equal 1, graph.role_families.length
      end
    end

    should "skip the snapshot rewrite for comment-only commits" do
      framework_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      suggestion_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        author_id = create(:person, tenant: @tenant).id.to_s
        handler = Frameworks::CommandHandler.new
        handler.create_framework(framework_id, "Engineering Growth")
        cat_id = SecureRandom.uuid_v7
        handler.add_capability_category(framework_id, cat_id, "Thinking")
        handler.add_capability(framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
        handler.suggest_edit(framework_id, suggestion_id, "capability", cap_id,
                             "description", "Proposed", author_id, mode: :suggesting)
        before = FrameworkExplorerGraph.find_by(framework_id: framework_id).updated_at

        sleep 0.01 # ensure timestamp resolution
        comment_id = SecureRandom.uuid_v7
        handler.comment_on_suggestion(framework_id, suggestion_id, comment_id,
                                      body: "Discussing", author_id: author_id)
        handler.edit_suggestion_comment(framework_id, comment_id,
                                        body: "Revised", edited_by_id: author_id)
        handler.delete_suggestion_comment(framework_id, comment_id, deleted_by_id: author_id)

        # Chat traffic changes nothing the graph renders — no row churn.
        assert_equal before, FrameworkExplorerGraph.find_by(framework_id: framework_id).updated_at

        # A graph-relevant command still rewrites it.
        sleep 0.01
        Frameworks::CommandHandler.new.add_role_family(framework_id, SecureRandom.uuid_v7, "Engineering")
        assert_operator FrameworkExplorerGraph.find_by(framework_id: framework_id).updated_at, :>, before
      end
    end

    should "never end up with a snapshot but no events (or vice versa)" do
      # Atomicity: we force a failure after the aggregate's command applies
      # in-memory but before the outer transaction commits. Neither the
      # events nor the ExplorerGraph row should exist after the rollback.
      framework_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(ActiveRecord::RecordInvalid) do
          Frameworks::Repository.new.with_framework(framework_id) do |framework|
            framework.create(framework_id, "Will Roll Back")
            # Simulate a projection-side failure landing inside the same tx.
            # Any RecordInvalid raised after block.call but before commit will
            # roll everything back.
            raise ActiveRecord::RecordInvalid.new(FrameworkExplorerGraph.new)
          end
        end

        stream = EventStreamNaming.framework_stream(framework_id)
        assert_equal 0, Rails.configuration.event_store.read.stream(stream).count,
                     "expected no events after rollback"
        assert_nil FrameworkExplorerGraph.find_by(framework_id: framework_id),
                   "expected no ExplorerGraph row after rollback"
      end
    end
  end
end
