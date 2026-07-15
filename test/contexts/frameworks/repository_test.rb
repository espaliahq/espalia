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

    should "not write the snapshot when the block only reads" do
      framework_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::CommandHandler.new.create_framework(framework_id, "Engineering Growth")
        before = FrameworkExplorerGraph.find_by(framework_id: framework_id).updated_at

        sleep 0.01 # ensure timestamp resolution
        Frameworks::Repository.new.with_framework(framework_id) { |framework| framework }

        assert_equal before, FrameworkExplorerGraph.find_by(framework_id: framework_id).updated_at
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

  context "#batch unit of work" do
    should "run many commands with one store and one graph write" do
      framework_id = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new

        graph_writes = 0
        original_store = Frameworks::ExplorerGraph.method(:store)
        Frameworks::ExplorerGraph.stub(:store, lambda { |id, graph|
          graph_writes += 1
          original_store.call(id, graph)
        }) do
          handler.batch(framework_id) do
            handler.create_framework(framework_id, "Engineering Growth")
            handler.add_role_family(framework_id, SecureRandom.uuid_v7, "Engineering")
            handler.add_capability_category(framework_id, cat_id, "Thinking")
            # Depends on in-batch state: a fresh per-command replay would not
            # see the (unstored) category and the aggregate would refuse this.
            handler.add_capability(framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
          end
        end

        assert_equal 1, graph_writes, "expected exactly one graph write for the whole batch"

        stream = EventStreamNaming.framework_stream(framework_id)
        # create emits FrameworkCreated + DraftVersionStarted (v1 bootstrap).
        assert_equal 5, Rails.configuration.event_store.read.stream(stream).count

        # Sync projections ran at the single store — read models materialised.
        assert FrameworkState::Framework.find_by(framework_id: framework_id)
        assert_equal 1, FrameworkState::RoleFamily.where(framework_id: framework_id).count

        graph = Frameworks::ExplorerGraph.load(framework_id)
        assert_equal 1, graph.capability_categories.length
        assert_equal 1, graph.capability_categories.first.capabilities.length
      end
    end

    should "roll back events, graph, and read models together on failure" do
      framework_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new

        assert_raises(RuntimeError) do
          handler.batch(framework_id) do
            handler.create_framework(framework_id, "Will Roll Back")
            raise "boom"
          end
        end

        stream = EventStreamNaming.framework_stream(framework_id)
        assert_equal 0, Rails.configuration.event_store.read.stream(stream).count
        assert_nil FrameworkExplorerGraph.find_by(framework_id: framework_id)
        assert_nil FrameworkState::Framework.find_by(framework_id: framework_id)
      end
    end

    should "let a second handler instance join the batch on the same thread" do
      framework_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new

        graph_writes = 0
        original_store = Frameworks::ExplorerGraph.method(:store)
        Frameworks::ExplorerGraph.stub(:store, lambda { |id, graph|
          graph_writes += 1
          original_store.call(id, graph)
        }) do
          handler.batch(framework_id) do
            handler.create_framework(framework_id, "Engineering Growth")
            # A fresh handler (fresh repository instance) — the house pattern
            # in every Operations class — must join the same unit of work,
            # not load/append against the un-stored stream.
            Frameworks::CommandHandler.new.add_role_family(
              framework_id, SecureRandom.uuid_v7, "Engineering"
            )
          end
        end

        assert_equal 1, graph_writes
        stream = EventStreamNaming.framework_stream(framework_id)
        assert_equal 3, Rails.configuration.event_store.read.stream(stream).count
        assert_equal 1, FrameworkState::RoleFamily.where(framework_id: framework_id).count
      end
    end

    should "abort instead of committing a rescued, partially-applied command" do
      framework_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        repository = Frameworks::Repository.new

        assert_raises(Frameworks::Repository::BatchAbortedError) do
          handler.batch(framework_id) do
            handler.create_framework(framework_id, "Engineering Growth")
            begin
              # A command that applies an event and THEN fails, rescued by the
              # bulk loop ("log the bad row, keep going") — single-command
              # dispatch would discard the event; the batch must not commit it.
              repository.with_framework(framework_id) do |framework|
                framework.add_role_family(framework_id, SecureRandom.uuid_v7, "Orphaned")
                raise "boom"
              end
            rescue RuntimeError
              nil
            end
          end
        end

        stream = EventStreamNaming.framework_stream(framework_id)
        assert_equal 0, Rails.configuration.event_store.read.stream(stream).count
        assert_nil FrameworkExplorerGraph.find_by(framework_id: framework_id)
      end
    end

    should "refuse writes to a different framework inside a batch" do
      framework_id = SecureRandom.uuid_v7
      other_framework_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new

        handler.batch(framework_id) do
          handler.create_framework(framework_id, "Engineering Growth")
          # Its transaction would silently join the batch's and roll back
          # with it — refuse rather than couple the two streams' fates.
          assert_raises(ArgumentError) do
            Frameworks::CommandHandler.new.create_framework(other_framework_id, "Other")
          end
        end

        stream = EventStreamNaming.framework_stream(framework_id)
        assert_operator Rails.configuration.event_store.read.stream(stream).count, :>, 0
        other_stream = EventStreamNaming.framework_stream(other_framework_id)
        assert_equal 0, Rails.configuration.event_store.read.stream(other_stream).count
      end
    end

    should "return the block's value from with_framework on both paths" do
      framework_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        repository = Frameworks::Repository.new

        result = repository.with_framework(framework_id) do |framework|
          framework.create(framework_id, "Engineering Growth")
          :single
        end
        assert_equal :single, result

        batched = nil
        repository.batch(framework_id) do
          batched = repository.with_framework(framework_id) { |_framework| :batched }
        end
        assert_equal :batched, batched
      end
    end

    should "refuse nested batches" do
      framework_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        repository = Frameworks::Repository.new
        assert_raises(ArgumentError) do
          repository.batch(framework_id) do
            repository.batch(framework_id) { nil }
          end
        end
      end
    end

    should "leave single-command dispatch unaffected after a batch" do
      framework_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        repository = Frameworks::Repository.new
        handler = Frameworks::CommandHandler.new(repository: repository)

        handler.batch(framework_id) do
          handler.create_framework(framework_id, "Engineering Growth")
        end

        # The batch cleared itself — this loads fresh, stores, snapshots.
        handler.add_role_family(framework_id, SecureRandom.uuid_v7, "Engineering")

        graph = Frameworks::ExplorerGraph.load(framework_id)
        assert_equal 1, graph.role_families.length
      end
    end
  end
end
