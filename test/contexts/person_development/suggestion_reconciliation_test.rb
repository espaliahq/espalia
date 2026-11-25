# frozen_string_literal: true

require "test_helper"
require_relative "../../support/placement_suggestion_fixture"

# Catching the development streams up with what the release before
# suggestion events wrote ([#539](https://github.com/espaliahq/espalia/issues/539) c3).
class PersonDevelopment::SuggestionReconciliationTest < ActiveSupport::TestCase
  include PlacementSuggestionFixture

  PROJECTION = PersonDevelopment::Projections::EvidenceSuggestions

  setup do
    build_placement_fixture
    @item = record_peer_feedback
    @other_item = record_peer_feedback(content: "Alex paired with two new starters on the deploy pipeline.")
    ActsAsTenant.with_tenant(@tenant) do
      @pending = written(@item, @ownership, 3, "pending")
      @superseded = written(@item, @ownership, 4, "superseded")
      @dismissed = written(@item, @collaboration, 3, "dismissed", decided_by_id: @morgan.id, decided_at: 2.hours.ago,
                           dismiss_reason: "Not this level")
      @edited = written(@other_item, @ownership, 3, "edited", decided_by_id: @morgan.id, decided_at: 1.hour.ago)
    end
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def event_store = Rails.configuration.event_store

  def stream = EventStreamNaming.person_development_stream(@alex.id, @framework_id, tenant: @tenant)

  # Written behind the projection's back, as the release before this one does.
  def written(item, capability, level, status, **attrs)
    create(:evidence_placement_suggestion, tenant: @tenant, item: item, capability_stable_id: capability.stable_id,
           level_ordinal: level, status: status, generated_at: 3.hours.ago, **attrs)
  end

  def reconcile = PersonDevelopment::SuggestionReconciliation.new(@tenant).call

  def aggregate = ActsAsTenant.with_tenant(@tenant) { PersonDevelopment::Repository.new.load(@alex.id, @framework_id) }

  def table
    ActsAsTenant.with_tenant(@tenant) do
      EvidencePlacementSuggestion.order(:id).map { it.attributes.except("created_at", "updated_at") }
    end
  end

  should "record every row the stream lacks, and nothing on a second run" do
    report = reconcile

    assert_equal [ 4, 0, 0 ], [ report.added, report.removed, report.changed ]
    assert_equal %w[pending superseded dismissed accepted],
      [ @pending, @superseded, @dismissed, @edited ].map { aggregate.suggestion_status(it.id) }
    assert_no_difference(-> { event_store.read.stream(stream).count }) { assert_equal 0, reconcile.recorded }
  end

  should "leave a forgotten person's rows out of their stream" do
    ActsAsTenant.with_tenant(@tenant) { @alex.update_columns(forgotten_at: Time.current, name: "Former member", email: nil) }

    assert_equal 0, reconcile.added
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.migrate_framework_version(@alex.id, @framework_id, 1, 2, [
        { from_stable_id: @collaboration.stable_id, to_stable_id: @ownership.stable_id, mapping_type: "evolved" }
      ])
    end

    assert_empty event_store.read.stream(stream).of_type([ PersonDevelopment::Events::EvidencePlacementSuggested,
                                                           PersonDevelopment::Events::EvidencePlacementSuggestionDismissed ]).to_a
  end

  should "follow a row the release before reopened with a later run" do
    reconcile
    @pending.update!(status: "superseded")
    @pending.update!(status: "pending", rationale: "Ran the whole follow-up.", generated_at: 1.minute.ago)

    assert_equal 1, reconcile.added
    assert_equal 0, reconcile.added
  end

  def rebuild
    PROJECTION.reset!(tenant: @tenant)
    event_store.read.stream(stream).of_type(PROJECTION.handled_events).each { PROJECTION.new.call(it) }
  end

  should "leave a table that a rebuild from the stream writes back the same" do
    reconcile
    before = table

    rebuild

    assert_equal before, table
  end

  should "catch up a row the stream lacks before a migration collides with it" do
    retiring = ActsAsTenant.with_tenant(@tenant) { written(@other_item, @collaboration, 4, "pending") }
    reconcile
    survivor = ActsAsTenant.with_tenant(@tenant) do
      written(@other_item, @ownership, 4, "dismissed", decided_by_id: @morgan.id, decided_at: 1.hour.ago)
    end

    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.migrate_framework_version(@alex.id, @framework_id, 1, 2, [
        { from_stable_id: @collaboration.stable_id, to_stable_id: @ownership.stable_id, mapping_type: "evolved" }
      ])
    end

    assert_nil aggregate.suggestion_status(retiring.id)
    assert_equal "dismissed", aggregate.suggestion_status(survivor.id)
    before = table
    rebuild
    assert_equal before, table
  end
end
