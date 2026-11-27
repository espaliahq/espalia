# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/placement_suggestion_fixture"

# The suggestion table, written from the development stream
# ([#539](https://github.com/espaliahq/espalia/issues/539) c3).
class PersonDevelopment::Projections::EvidenceSuggestionsTest < ActiveSupport::TestCase
  include PlacementSuggestionFixture

  setup do
    build_placement_fixture
    @item = record_peer_feedback
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def event_store = Rails.configuration.event_store

  def stream = EventStreamNaming.person_development_stream(@alex.id, @framework_id, tenant: @tenant)

  def with_aggregate(&block)
    ActsAsTenant.with_tenant(@tenant) { PersonDevelopment::Repository.new.with_person_development(@alex.id, @framework_id, &block) }
  end

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

  def link(suggestion_id, valence:, capability: @ownership, level: 3)
    with_aggregate do |agg|
      agg.add_evidence_link(@item.id, capability_stable_id: capability.stable_id, level_ordinal: level,
                            linked_by_id: @morgan.id, valence: valence, via_suggestion_id: suggestion_id)
    end
  end

  def dismiss(suggestion_id)
    with_aggregate { |agg| agg.dismiss_suggestion(suggestion_id, evidence_id: @item.id, dismissed_by_id: @morgan.id, reason: "Not this") }
  end

  def rows = ActsAsTenant.with_tenant(@tenant) { EvidencePlacementSuggestion.where(evidence_id: @item.id).order(:level_ordinal).to_a }

  def row_at(capability, level) = rows.find { it.capability_stable_id == capability.stable_id && it.level_ordinal == level }

  def migrate(from, to)
    event_store.with_metadata(tenant_id: @tenant.id, person_id: @alex.id, framework_id: @framework_id) do
      event_store.publish(PersonDevelopment::Events::FrameworkVersionMigrated.new(data: {
        framework_id: @framework_id, old_version: 1, new_version: 2,
        mappings: [ { from_stable_id: from.stable_id, to_stable_id: to.stable_id, mapping_type: "evolved" } ]
      }), stream_name: stream)
    end
  end

  def snapshot = rows.map { it.attributes.except("created_at", "updated_at") }.sort_by { it["id"] }

  should "write a row per suggestion, keyed by its id, and supersede the old set" do
    suggest(proposal(@ownership, 3), proposal(@ownership, 4))
    first = rows
    suggest(proposal(@ownership, 3))

    assert_equal first.map(&:id), rows.map(&:id)
    assert_equal %w[pending superseded], rows.map(&:status)
    assert_equal [ @alex.id, @framework_id, "test-model" ], [ rows.first.person_id, rows.first.framework_id, rows.first.model ]
  end

  should "record a dismissal with who and why" do
    suggest(proposal)
    dismiss(rows.first.id)

    row = rows.first
    assert_equal [ "dismissed", @morgan.id, "Not this" ], [ row.status, row.decided_by_id, row.dismiss_reason ]
    assert row.decided_at
  end

  should "read a link with the suggested valence as accepted, and another as edited" do
    suggest(proposal(@ownership, 3), proposal(@ownership, 4))
    link(row_at(@ownership, 3).id, valence: "demonstrated")
    link(row_at(@ownership, 4).id, valence: "growth_area", level: 4)

    assert_equal %w[accepted edited], rows.map(&:status)
    assert_equal [ @morgan.id ] * 2, rows.map(&:decided_by_id)
  end

  should "accept a suggestion on a link that already holds its valence" do
    with_aggregate do |agg|
      agg.add_evidence_link(@item.id, capability_stable_id: @ownership.stable_id, level_ordinal: 3,
                            linked_by_id: @jordan.id, valence: "demonstrated")
    end
    suggest(proposal)
    with_aggregate do |agg|
      agg.set_evidence_link_valence(@item.id, capability_stable_id: @ownership.stable_id, level_ordinal: 3,
                                    valence: "demonstrated", changed_by_id: @morgan.id, via_suggestion_id: rows.first.id)
    end

    assert_equal [ "accepted", @morgan.id ], [ rows.first.status, rows.first.decided_by_id ]
  end

  should "keep a dismissal when a migration moves another suggestion onto its cell" do
    suggest(proposal(@ownership, 3), proposal(@collaboration, 3))
    dismiss(row_at(@collaboration, 3).id)
    kept = row_at(@collaboration, 3).id
    migrate(@ownership, @collaboration)

    assert_equal [ [ kept, "dismissed" ] ], rows.map { [ it.id, it.status ] }
  end

  should "let a moved dismissal replace an open suggestion" do
    suggest(proposal(@ownership, 3), proposal(@collaboration, 3))
    dismissed = row_at(@ownership, 3).id
    dismiss(dismissed)
    migrate(@ownership, @collaboration)

    assert_equal [ [ dismissed, @collaboration.stable_id, "dismissed" ] ], rows.map { [ it.id, it.capability_stable_id, it.status ] }
  end

  should "rebuild the same rows from the stream" do
    suggest(proposal(@ownership, 3), proposal(@ownership, 4), proposal(@collaboration, 3))
    dismiss(row_at(@ownership, 4).id)
    link(row_at(@ownership, 3).id, valence: "growth_area")
    suggest(proposal(@collaboration, 4))
    migrate(@ownership, @collaboration)
    before = snapshot

    projection = PersonDevelopment::Projections::EvidenceSuggestions
    projection.reset!(tenant: @tenant)
    assert_empty rows
    event_store.read.stream(stream).of_type(projection.handled_events).each { projection.new.call(it) }

    assert_equal before, snapshot
  end

  def forget(person)
    event_store.with_metadata(tenant_id: @tenant.id) do
      event_store.publish(OrgGraph::Events::PersonForgotten.new(data: {
        person_id: person.id, provider: "espalia", effective_on: "2026-11-27", reason: "retention", retention_years: 1,
        requested_by_id: nil
      }), stream_name: ActsAsTenant.with_tenant(@tenant) { EventStreamNaming.person_stream(person.id) })
    end
  end

  should "close the pending rows of a forgotten person and leave the decided ones" do
    suggest(proposal(@ownership, 3), proposal(@ownership, 4), proposal(@collaboration, 3))
    link(row_at(@ownership, 3).id, valence: "demonstrated")
    dismiss(row_at(@ownership, 4).id)

    forget(@jordan)
    assert_equal "pending", row_at(@collaboration, 3).status

    forget(@alex)
    assert_equal "accepted", row_at(@ownership, 3).status
    assert_equal "dismissed", row_at(@ownership, 4).status
    assert_equal "closed", row_at(@collaboration, 3).status
  end

  should "close them again on a rebuild, which reads both streams in the order they were written" do
    suggest(proposal(@ownership, 3), proposal(@collaboration, 3))
    dismiss(row_at(@ownership, 3).id)
    forget(@alex)
    before = snapshot

    projection = PersonDevelopment::Projections::EvidenceSuggestions
    projection.reset!(tenant: @tenant)
    Projections::Replayer.replay(projection_class: projection, tenant: @tenant)

    assert_equal before, snapshot
    assert_equal %w[closed dismissed], rows.map(&:status).sort
  end

  should "keep a closed row closed when the same cell is suggested again" do
    suggest(proposal(@ownership, 3))
    forget(@alex)
    suggest(proposal(@ownership, 3))

    assert_equal [ "closed" ], rows.map(&:status)
  end

  should "nudge the open assessment when a suggestion is dismissed, and not when one is made" do
    broadcasts = []
    Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*args, **_kw) { broadcasts << args }) do
      suggest(proposal)
      assert_empty broadcasts

      dismiss(rows.sole.id)
    end

    assert_equal [ [ "assessment_updates", @framework_id, @alex.id ] ], broadcasts
  end
end
