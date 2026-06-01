# frozen_string_literal: true

require "test_helper"

class AuditMetadataTest < ActiveSupport::TestCase
  teardown { AuditMetadata.clear! }

  context "current" do
    should "return an empty hash by default" do
      AuditMetadata.clear!
      assert_equal({}, AuditMetadata.current)
    end
  end

  context "seed! / clear!" do
    should "set the current acting_via" do
      AuditMetadata.seed!(acting_via: :web)
      assert_equal({ acting_via: :web }, AuditMetadata.current)
    end

    should "include client_application_id when provided" do
      AuditMetadata.seed!(acting_via: :mcp, client_application_id: "app-123")
      assert_equal(
        { acting_via: :mcp, client_application_id: "app-123" },
        AuditMetadata.current
      )
    end

    should "omit client_application_id when nil" do
      AuditMetadata.seed!(acting_via: :web)
      refute_includes AuditMetadata.current.keys, :client_application_id
    end

    should "include actor_id and correlation_id when provided" do
      AuditMetadata.seed!(acting_via: :web, actor_id: "person-7", correlation_id: "req-42")
      assert_equal(
        { acting_via: :web, actor_id: "person-7", correlation_id: "req-42" },
        AuditMetadata.current
      )
    end

    should "omit actor_id and correlation_id when nil" do
      AuditMetadata.seed!(acting_via: :web)
      refute_includes AuditMetadata.current.keys, :actor_id
      refute_includes AuditMetadata.current.keys, :correlation_id
    end

    should "include impersonator_id when provided" do
      AuditMetadata.seed!(acting_via: :web, actor_id: "target-1", impersonator_id: "admin-9")
      assert_equal "admin-9", AuditMetadata.current[:impersonator_id]
      assert_equal "target-1", AuditMetadata.current[:actor_id]
    end

    should "omit impersonator_id when nil" do
      AuditMetadata.seed!(acting_via: :web, actor_id: "target-1")
      refute_includes AuditMetadata.current.keys, :impersonator_id
    end

    should "include impersonation_active only when true" do
      AuditMetadata.seed!(acting_via: :web, impersonation_active: true)
      assert_equal true, AuditMetadata.current[:impersonation_active]
    end

    should "omit impersonation_active when false" do
      AuditMetadata.seed!(acting_via: :web, impersonation_active: false)
      refute_includes AuditMetadata.current.keys, :impersonation_active
    end

    should "clear the slot" do
      AuditMetadata.seed!(acting_via: :web)
      AuditMetadata.clear!
      assert_equal({}, AuditMetadata.current)
    end

    should "reject unknown acting_via values" do
      assert_raises(ArgumentError) { AuditMetadata.seed!(acting_via: :magic) }
    end
  end

  context "with" do
    should "set context for the duration of the block and restore on exit" do
      AuditMetadata.seed!(acting_via: :web)

      seen = nil
      AuditMetadata.with(acting_via: :hris) { seen = AuditMetadata.current }

      assert_equal({ acting_via: :hris }, seen)
      assert_equal({ acting_via: :web }, AuditMetadata.current)
    end

    should "restore even when the block raises" do
      AuditMetadata.seed!(acting_via: :web)

      assert_raises(RuntimeError) do
        AuditMetadata.with(acting_via: :mcp) { raise "boom" }
      end

      assert_equal({ acting_via: :web }, AuditMetadata.current)
    end

    should "restore to nil when no prior context was seeded" do
      AuditMetadata.clear!
      AuditMetadata.with(acting_via: :hris) { :noop }
      assert_equal({}, AuditMetadata.current)
    end
  end

  context "wrap_event_store" do
    should "be a transparent no-op when nothing is seeded" do
      AuditMetadata.clear!
      result = AuditMetadata.wrap_event_store { :body_ran }
      assert_equal :body_ran, result
    end

    should "set the event_store's ambient metadata for the duration of the block" do
      AuditMetadata.seed!(acting_via: :mcp, client_application_id: "app-xyz")

      seen_during_block = nil
      AuditMetadata.wrap_event_store do
        seen_during_block = Rails.configuration.event_store.metadata
      end

      # Stringified at the event-store boundary because
      # ruby_event_store::Metadata only accepts a fixed set of value types
      # (String/Integer/Float/Date/Time/Bool/nil/Hash/Array — no Symbol).
      # The thread-local API still uses Symbols (see the seed! tests above).
      assert_equal "mcp",     seen_during_block[:acting_via]
      assert_equal "app-xyz", seen_during_block[:client_application_id]
      # And it's fully cleared on exit (not just "different from mcp" —
      # that'd pass for any other surprise value).
      assert_nil Rails.configuration.event_store.metadata[:acting_via]
    end

    should "carry actor_id and correlation_id onto the event_store metadata" do
      AuditMetadata.seed!(acting_via: :web, actor_id: "person-7", correlation_id: "req-42")

      seen = nil
      AuditMetadata.wrap_event_store { seen = Rails.configuration.event_store.metadata }

      assert_equal "person-7", seen[:actor_id]
      assert_equal "req-42",   seen[:correlation_id]
    end
  end
end
