# frozen_string_literal: true

require "test_helper"

class Frameworks::SyncHandlers::FrameworkVersionMigrationSyncTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant

    @handler = Frameworks::SyncHandlers::FrameworkVersionMigrationSync.new
    @framework_id = SecureRandom.uuid_v7

    # Both stable_ids must exist as FrameworkState::Capability rows for
    # the handler's name lookup (and for downstream MatrixDataBuilder
    # filtering to find the survivor).
    @from_stable_id = SecureRandom.uuid_v7
    @to_stable_id   = SecureRandom.uuid_v7
    cat = create(:framework_capability_category, framework_id: @framework_id, name: "Eng", ordinal: 1)
    create(:framework_capability, category_id: cat.category_id,
      stable_id: @from_stable_id, name: "Old Cap", status: "archived")
    create(:framework_capability, category_id: cat.category_id,
      stable_id: @to_stable_id, name: "Survivor Cap", status: "active")

    create(:framework_migration_mapping,
      framework_id: @framework_id,
      from_stable_id: @from_stable_id,
      to_stable_id: @to_stable_id,
      mapping_type: "same",
      requires_reassessment: false,
      published_version: 2,
      reason: "test")

    # Two people assigned to the same framework — both should receive
    # the migration.
    @p1 = SecureRandom.uuid_v7
    @p2 = SecureRandom.uuid_v7
    [ @p1, @p2 ].each do |pid|
      PersonDevelopment::CommandHandler.new
        .assign_to_framework(pid, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
    end
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  def publish_event(version: 2)
    Frameworks::Events::FrameworkVersionPublished.new(
      data: { framework_id: @framework_id, version: version, published_by: "tester" },
      metadata: { tenant_id: @tenant.id }
    )
  end

  context "on FrameworkVersionPublished" do
    should "dispatch migrate_framework_version once per affected person stream" do
      @handler.call(publish_event)

      [ @p1, @p2 ].each do |pid|
        stream = EventStreamNaming.person_development_stream(pid, @framework_id)
        events = Rails.configuration.event_store.read.stream(stream).to_a
        migrated = events.find { |e| e.is_a?(PersonDevelopment::Events::FrameworkVersionMigrated) }
        assert_not_nil migrated, "expected FrameworkVersionMigrated on stream for #{pid}"
        assert_equal 1, migrated.data[:old_version]
        assert_equal 2, migrated.data[:new_version]
        assert_equal 1, migrated.data[:mappings].size

        mapping = migrated.data[:mappings].first
        assert_equal @from_stable_id, mapping[:from_stable_id]
        assert_equal @to_stable_id,   mapping[:to_stable_id]
        assert_equal "same",          mapping[:mapping_type]
        assert_equal "Old Cap",       mapping[:from_capability_name]
        assert_equal "Survivor Cap",  mapping[:to_capability_name]
      end
    end

    should "include per-person rating/evidence/comment counts in the payload" do
      # Plant one rating on the from_stable_id for @p1; @p2 has no data.
      cycle = create(:assessment_cycle, :closed,
        tenant: @tenant, framework_id: @framework_id, framework_version: 1)
      create(:assessment_level_rating, tenant: @tenant,
        person_id: @p1, framework_id: @framework_id,
        capability_stable_id: @from_stable_id, level_ordinal: 3,
        self_rated_frequency: "consistent",
        cycle_id: cycle.cycle_id)

      @handler.call(publish_event)

      stream_p1 = EventStreamNaming.person_development_stream(@p1, @framework_id)
      migrated = Rails.configuration.event_store.read.stream(stream_p1).to_a
        .find { |e| e.is_a?(PersonDevelopment::Events::FrameworkVersionMigrated) }
      assert_equal 1, migrated.data[:mappings].first[:counts][:ratings]
      assert_equal 0, migrated.data[:mappings].first[:counts][:evidence]
      assert_equal 0, migrated.data[:mappings].first[:counts][:comments]

      stream_p2 = EventStreamNaming.person_development_stream(@p2, @framework_id)
      migrated_p2 = Rails.configuration.event_store.read.stream(stream_p2).to_a
        .find { |e| e.is_a?(PersonDevelopment::Events::FrameworkVersionMigrated) }
      assert_equal 0, migrated_p2.data[:mappings].first[:counts][:ratings]
    end

    should "skip participants whose current open cycle has completed alignment" do
      # @p1 has a completed (aligned) assessment in an open cycle — frozen.
      cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id, framework_version: 1)
      AssessmentCycleEnrollment.create!(tenant: @tenant, cycle_id: cycle.cycle_id,
        person_id: @p1, status: "enrolled", enrolled_at: Time.current)
      AssessmentCycleProgress.create!(tenant: @tenant, cycle_id: cycle.cycle_id,
        person_id: @p1, status: "aligned", aligned_at: Time.current)

      @handler.call(publish_event)

      p1_stream = EventStreamNaming.person_development_stream(@p1, @framework_id)
      assert_nil Rails.configuration.event_store.read.stream(p1_stream).to_a
        .find { |e| e.is_a?(PersonDevelopment::Events::FrameworkVersionMigrated) },
        "completed-alignment participant must not be migrated"

      # @p2 (no cycle / not completed) still migrates.
      p2_stream = EventStreamNaming.person_development_stream(@p2, @framework_id)
      assert_not_nil Rails.configuration.event_store.read.stream(p2_stream).to_a
        .find { |e| e.is_a?(PersonDevelopment::Events::FrameworkVersionMigrated) },
        "in-progress participant should still migrate"
    end

    should "no-op when the publish has no migration mappings" do
      FrameworkState::MigrationMapping.delete_all

      @handler.call(publish_event(version: 3))

      [ @p1, @p2 ].each do |pid|
        stream = EventStreamNaming.person_development_stream(pid, @framework_id)
        events = Rails.configuration.event_store.read.stream(stream).to_a
        assert_nil events.find { |e| e.is_a?(PersonDevelopment::Events::FrameworkVersionMigrated) }
      end
    end

    should "compute counts via a bounded number of grouped queries regardless of person count" do
      extra_people = 5.times.map { SecureRandom.uuid_v7 }
      extra_people.each do |pid|
        PersonDevelopment::CommandHandler.new
          .assign_to_framework(pid, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
      end

      count_queries = lambda do |&block|
        events = 0
        sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
          next if payload[:cached]
          next if %w[SCHEMA TRANSACTION].include?(payload[:name])
          sql = payload[:sql].to_s
          next unless sql.start_with?("SELECT")
          next unless sql.include?("assessment_level_ratings") ||
                      sql.include?("evidence_items") ||
                      sql.include?("person_development_comments")
          events += 1
        end
        block.call
        ActiveSupport::Notifications.unsubscribe(sub)
        events
      end

      observed = count_queries.call { @handler.call(publish_event) }
      assert_equal 3, observed,
        "expected exactly 3 grouped count queries (ratings + evidence + comments); got #{observed}"
    end

    should "be idempotent — second call is a no-op via the aggregate guard" do
      @handler.call(publish_event)
      @handler.call(publish_event)

      stream = EventStreamNaming.person_development_stream(@p1, @framework_id)
      migrated_events = Rails.configuration.event_store.read.stream(stream).to_a
        .select { |e| e.is_a?(PersonDevelopment::Events::FrameworkVersionMigrated) }
      assert_equal 1, migrated_events.size
    end
  end
end
