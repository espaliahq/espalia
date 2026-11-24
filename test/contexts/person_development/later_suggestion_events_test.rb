# frozen_string_literal: true

require "test_helper"
require_relative "../../support/placement_suggestion_fixture"

# Suggestion events reach the development stream from a later release while
# this one may still be serving ([#539](https://github.com/espaliahq/espalia/issues/539) c3).
# This release writes none of them, but must load them.
class PersonDevelopment::LaterSuggestionEventsTest < ActiveSupport::TestCase
  include PlacementSuggestionFixture

  setup do
    build_placement_fixture
    @item = record_peer_feedback
    ActsAsTenant.with_tenant(@tenant) do
      @suggestion = create(:evidence_placement_suggestion, tenant: @tenant, item: @item,
        capability_stable_id: @ownership.stable_id, level_ordinal: 3, valence: "demonstrated", confidence: 0.82)
    end
    @replaced, @dismissed, @held = Array.new(3) { SecureRandom.uuid_v7 }
    event_store.with_metadata(tenant_id: @tenant.id) do
      event_store.append([
        suggested(@suggestion.id, 3),
        suggested(@replaced, 2),
        PersonDevelopment::Events::EvidencePlacementSuggestionsSuperseded.new(data: {
          evidence_id: @item.id, suggestion_ids: [ @replaced ]
        }),
        suggested(@dismissed, 4),
        PersonDevelopment::Events::EvidencePlacementSuggestionDismissed.new(data: {
          suggestion_id: @dismissed, evidence_id: @item.id, dismissed_by_id: @morgan.id,
          reason: "Not this level", dismissed_at: "2026-11-20T10:00:00Z", already_held: false
        }),
        suggested(@held, 1, already_held: true, status: "edited", decided_by_id: @morgan.id,
          decided_at: "2026-11-19T10:00:00Z")
      ], stream_name: stream)
    end
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def event_store = Rails.configuration.event_store

  def stream = EventStreamNaming.person_development_stream(@alex.id, @framework_id, tenant: @tenant)

  def suggested(id, level, already_held: false, **held)
    PersonDevelopment::Events::EvidencePlacementSuggested.new(data: {
      suggestion_id: id, evidence_id: @item.id, capability_stable_id: @ownership.stable_id, level_ordinal: level,
      valence: "demonstrated", confidence: "0.8", rationale: "Owned the follow-up.", provider: "anthropic",
      model: "test-model", prompt_version: "v1", generated_at: "2026-11-18T10:00:00Z", already_held: already_held,
      **held
    })
  end

  def aggregate = ActsAsTenant.with_tenant(@tenant) { PersonDevelopment::Repository.new.load(@alex.id, @framework_id) }

  should "load them, and still accept a suggestion as this release does" do
    result = ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::AcceptEvidenceSuggestion.call(context: context_for(@morgan), params: { suggestion_id: @suggestion.id })
    end

    assert_equal "accepted", result[:status]
    assert_equal({ @suggestion.id => "accepted", @replaced => "superseded", @dismissed => "dismissed", @held => "accepted" },
      [ @suggestion.id, @replaced, @dismissed, @held ].index_with { aggregate.suggestion_status(it) })
  end

  should "leave a suggestion pending until a link names it" do
    assert_equal "pending", aggregate.suggestion_status(@suggestion.id)
    assert_nil aggregate.suggestion_status(SecureRandom.uuid_v7)
  end

  should "never reopen a decided suggestion when its id is superseded" do
    event_store.with_metadata(tenant_id: @tenant.id) do
      event_store.append(PersonDevelopment::Events::EvidencePlacementSuggestionsSuperseded.new(data: {
        evidence_id: @item.id, suggestion_ids: [ @dismissed, @held ]
      }), stream_name: stream)
    end

    assert_equal %w[dismissed accepted], [ @dismissed, @held ].map { aggregate.suggestion_status(it) }
  end

  def append(*events)
    event_store.with_metadata(tenant_id: @tenant.id) { event_store.append(events, stream_name: stream) }
  end

  def revalenced(suggestion_id)
    PersonDevelopment::Events::EvidenceLinkRevalenced.new(data: {
      evidence_id: @item.id, capability_stable_id: @ownership.stable_id, level_ordinal: 3,
      previous_valence: nil, valence: "growth_area", changed_by_id: @morgan.id, via_suggestion_id: suggestion_id
    })
  end

  def dismissal(suggestion_id)
    PersonDevelopment::Events::EvidencePlacementSuggestionDismissed.new(data: {
      suggestion_id: suggestion_id, evidence_id: @item.id, dismissed_by_id: @morgan.id,
      reason: nil, dismissed_at: "2026-11-21T10:00:00Z", already_held: false
    })
  end

  should "accept a suggestion through a revalenced link" do
    append(revalenced(@suggestion.id))

    assert_equal "accepted", aggregate.suggestion_status(@suggestion.id)
  end

  should "hold an accept that comes before its suggestion is recorded" do
    early = SecureRandom.uuid_v7
    append(revalenced(early), suggested(early, 5, already_held: true, status: "pending"))

    assert_equal "accepted", aggregate.suggestion_status(early)
  end

  should "keep a decision when the suggestion is recorded again" do
    append(suggested(@dismissed, 4), suggested(@held, 1))

    assert_equal %w[dismissed accepted], [ @dismissed, @held ].map { aggregate.suggestion_status(it) }
  end

  should "reopen a superseded suggestion when the model proposes its cell again" do
    append(suggested(@replaced, 2))

    assert_equal "pending", aggregate.suggestion_status(@replaced)
  end

  should "never flip a decision, whichever event comes after it" do
    append(revalenced(@dismissed), dismissal(@held), dismissal(@replaced))

    assert_equal %w[dismissed accepted superseded], [ @dismissed, @held, @replaced ].map { aggregate.suggestion_status(it) }
  end
end
