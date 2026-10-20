# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/placement_suggestion_fixture"

class PersonDevelopment::AsyncHandlers::PlacementSuggesterTest < ActiveJob::TestCase
  include PlacementSuggestionFixture

  setup { build_placement_fixture }
  teardown { ActsAsTenant.current_tenant = nil }

  def event_for(item, klass: PersonDevelopment::Events::EvidenceRecorded, acting_via: "web")
    klass.new(data: { evidence_id: item.id, source: item.source },
              metadata: { tenant_id: @tenant.id, acting_via: acting_via })
  end

  def handle(event) = PersonDevelopment::AsyncHandlers::PlacementSuggester.new.perform(event)

  should "enqueue suggestions for human feedback, recorded or edited" do
    item = record_peer_feedback
    assert_enqueued_with(job: Evidence::SuggestPlacementsJob, args: [ item.id ]) { handle(event_for(item)) }
    assert_enqueued_with(job: Evidence::SuggestPlacementsJob, args: [ item.id ]) do
      handle(event_for(item, klass: PersonDevelopment::Events::EvidenceUpdated))
    end
  end

  should "leave feedback written by a sync or a system job alone" do
    item = record_peer_feedback
    clear_enqueued_jobs
    assert_no_enqueued_jobs(only: Evidence::SuggestPlacementsJob) do
      handle(event_for(item, acting_via: "hris"))
      handle(event_for(item, acting_via: "system"))
    end
  end

  should "leave self feedback and tenants with suggestions off alone" do
    item = record_peer_feedback
    ActsAsTenant.with_tenant(@tenant) { item.update_columns(source: "self") }
    assert_no_enqueued_jobs(only: Evidence::SuggestPlacementsJob) { handle(event_for(item)) }

    ActsAsTenant.with_tenant(@tenant) do
      item.update_columns(source: "peer")
      @tenant.update!(evidence_suggestions_enabled: false)
    end
    assert_no_enqueued_jobs(only: Evidence::SuggestPlacementsJob) { handle(event_for(item)) }
  end

  should "leave pending suggestions behind once recorded feedback's jobs have run" do
    with_fake_suggestion_model(proposals: [ proposal(@ownership) ]) do
      perform_enqueued_jobs(only: [ PersonDevelopment::AsyncHandlers::PlacementSuggester, Evidence::SuggestPlacementsJob ]) do
        @item = record_peer_feedback
      end
    end

    ActsAsTenant.with_tenant(@tenant) do
      assert_equal [ [ @ownership.stable_id, 3, "pending" ] ],
        EvidencePlacementSuggestion.for_evidence(@item.id).pluck(:capability_stable_id, :level_ordinal, :status)
    end
  end

  should "be subscribed to the evidence events" do
    subscribers = Rails.configuration.event_store.subscribers_for(PersonDevelopment::Events::EvidenceRecorded)
    assert_includes subscribers, PersonDevelopment::AsyncHandlers::PlacementSuggester
  end
end
