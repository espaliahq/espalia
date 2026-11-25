# frozen_string_literal: true

require "test_helper"
require_relative "../../support/placement_suggestion_fixture"

# The aggregate's suggestion commands, and the rules they keep
# ([#539](https://github.com/espaliahq/espalia/issues/539) c3).
class PersonDevelopment::SuggestionCommandsTest < ActiveSupport::TestCase
  include PlacementSuggestionFixture

  setup do
    build_placement_fixture
    @item = record_peer_feedback
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def event_store = Rails.configuration.event_store

  def stream = EventStreamNaming.person_development_stream(@alex.id, @framework_id, tenant: @tenant)

  def with_aggregate
    result = nil
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::Repository.new.with_person_development(@alex.id, @framework_id) { result = yield(it) }
    end
    result
  end

  def aggregate = ActsAsTenant.with_tenant(@tenant) { PersonDevelopment::Repository.new.load(@alex.id, @framework_id) }

  def events_of(klass) = event_store.read.stream(stream).of_type([ klass ]).to_a

  def proposal(capability = @ownership, level = 3, valence: "demonstrated")
    { capability_stable_id: capability.stable_id, level_ordinal: level, valence: valence, confidence: "0.8",
      rationale: "Owned the follow-up." }
  end

  def suggest(*proposals)
    with_aggregate do |agg|
      agg.suggest_placements(@item.id, proposals: proposals, provider: "anthropic", model: "test-model",
                             prompt_version: "v1", generated_at: "2026-11-24T10:00:00Z")
    end
  end

  def migrate(from, to)
    event_store.with_metadata(tenant_id: @tenant.id, person_id: @alex.id, framework_id: @framework_id) do
      event_store.publish(PersonDevelopment::Events::FrameworkVersionMigrated.new(data: {
        framework_id: @framework_id, old_version: 1, new_version: 2,
        mappings: [ { from_stable_id: from.stable_id, to_stable_id: to.stable_id, mapping_type: "evolved" } ]
      }), stream_name: stream)
    end
  end

  def table
    ActsAsTenant.with_tenant(@tenant) do
      EvidencePlacementSuggestion.order(:id).map { it.attributes.except("created_at", "updated_at") }
    end
  end

  def rebuild
    projection = PersonDevelopment::Projections::EvidenceSuggestions
    projection.reset!(tenant: @tenant)
    event_store.read.stream(stream).of_type(projection.handled_events).each { projection.new.call(it) }
  end

  def suggestion_ids = events_of(PersonDevelopment::Events::EvidencePlacementSuggested).map { it.data[:suggestion_id] }

  context "suggest_placements" do
    should "supersede the pending set in one event and keep each cell's id" do
      suggest(proposal(@ownership, 3), proposal(@collaboration, 3))
      first_ids = suggestion_ids
      suggest(proposal(@ownership, 3), proposal(@ownership, 4))

      superseded = events_of(PersonDevelopment::Events::EvidencePlacementSuggestionsSuperseded)
      assert_equal 1, superseded.size
      assert_equal first_ids.sort, superseded.first.data[:suggestion_ids].sort
      assert_equal first_ids.first, suggestion_ids[2]
      assert_not_includes first_ids, suggestion_ids[3]
      assert_equal %w[pending superseded pending], [ first_ids.first, first_ids.last, suggestion_ids[3] ].map { aggregate.suggestion_status(it) }
    end

    should "never propose a cell someone decided on again" do
      suggest(proposal(@ownership, 3), proposal(@collaboration, 3))
      ownership_id, collaboration_id = suggestion_ids
      with_aggregate do |agg|
        agg.dismiss_suggestion(ownership_id, evidence_id: @item.id, dismissed_by_id: @morgan.id, reason: "Not this one")
        agg.add_evidence_link(@item.id, capability_stable_id: @collaboration.stable_id, level_ordinal: 3,
                              linked_by_id: @morgan.id, valence: "demonstrated", via_suggestion_id: collaboration_id)
      end

      assert_equal 0, suggest(proposal(@ownership, 3), proposal(@collaboration, 3))
      assert_equal 2, suggestion_ids.size
      assert_empty events_of(PersonDevelopment::Events::EvidencePlacementSuggestionsSuperseded)
    end

    should "write nothing when nothing is pending and nothing is proposed" do
      assert_no_difference -> { event_store.read.stream(stream).count } do
        assert_equal 0, suggest
      end
    end

    should "refuse withdrawn feedback" do
      with_aggregate { |agg| agg.withdraw_evidence(@item.id, withdrawn_by_id: @jordan.id, reason: "Wrong person") }

      assert_raises(PersonDevelopment::Aggregate::CommandError) { suggest(proposal) }
    end
  end

  context "deciding" do
    setup do
      suggest(proposal(@ownership, 3))
      @suggestion_id = suggestion_ids.first
    end

    should "refuse to dismiss or accept a suggestion that is no longer open" do
      with_aggregate { |agg| agg.dismiss_suggestion(@suggestion_id, evidence_id: @item.id, dismissed_by_id: @morgan.id) }

      error = assert_raises(PersonDevelopment::Aggregate::CommandError) do
        with_aggregate { |agg| agg.dismiss_suggestion(@suggestion_id, evidence_id: @item.id, dismissed_by_id: @alex.id) }
      end
      assert_equal "this suggestion was already dismissed", error.message
      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        with_aggregate do |agg|
          agg.add_evidence_link(@item.id, capability_stable_id: @ownership.stable_id, level_ordinal: 3,
                                linked_by_id: @morgan.id, valence: "demonstrated", via_suggestion_id: @suggestion_id)
        end
      end
    end

    should "refuse a superseded suggestion and let an unknown id through" do
      suggest(proposal(@collaboration, 3))

      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        with_aggregate { |agg| agg.dismiss_suggestion(@suggestion_id, evidence_id: @item.id, dismissed_by_id: @morgan.id) }
      end
      unknown = SecureRandom.uuid_v7
      with_aggregate { |agg| agg.dismiss_suggestion(unknown, evidence_id: @item.id, dismissed_by_id: @morgan.id) }
      assert_equal unknown, events_of(PersonDevelopment::Events::EvidencePlacementSuggestionDismissed).last.data[:suggestion_id]
    end

    should "record an accept that keeps the link's valence, and nothing for a plain one" do
      with_aggregate do |agg|
        agg.add_evidence_link(@item.id, capability_stable_id: @ownership.stable_id, level_ordinal: 3,
                              linked_by_id: @morgan.id, valence: "demonstrated")
      end
      revalence = ->(via) {
        with_aggregate do |agg|
          agg.set_evidence_link_valence(@item.id, capability_stable_id: @ownership.stable_id, level_ordinal: 3,
                                        valence: "demonstrated", changed_by_id: @morgan.id, via_suggestion_id: via)
        end
      }

      revalence.call(nil)
      assert_empty events_of(PersonDevelopment::Events::EvidenceLinkRevalenced)

      revalence.call(@suggestion_id)
      event = events_of(PersonDevelopment::Events::EvidenceLinkRevalenced).sole
      assert_equal [ "demonstrated", "demonstrated", @suggestion_id ], event.data.values_at(:previous_valence, :valence, :via_suggestion_id)
      assert_equal "accepted", aggregate.suggestion_status(@suggestion_id)
    end
  end

  context "a framework migration" do
    should "keep a dismissal when its suggestion collides with another" do
      suggest(proposal(@ownership, 3), proposal(@collaboration, 3))
      ownership_id, collaboration_id = suggestion_ids
      with_aggregate { |agg| agg.dismiss_suggestion(collaboration_id, evidence_id: @item.id, dismissed_by_id: @morgan.id) }

      migrate(@collaboration, @ownership)

      assert_equal "dismissed", aggregate.suggestion_status(collaboration_id)
      assert_nil aggregate.suggestion_status(ownership_id)
      assert_equal 0, suggest(proposal(@ownership, 3))
    end

    should "leave a table that a rebuild from the stream writes back the same after a collision" do
      suggest(proposal(@ownership, 3), proposal(@collaboration, 3), proposal(@collaboration, 4))
      _, collaboration_id, = suggestion_ids
      with_aggregate { |agg| agg.dismiss_suggestion(collaboration_id, evidence_id: @item.id, dismissed_by_id: @morgan.id) }
      migrate(@collaboration, @ownership)
      before = table

      rebuild

      assert_equal 2, before.size
      assert_equal before, table
    end
  end
end
