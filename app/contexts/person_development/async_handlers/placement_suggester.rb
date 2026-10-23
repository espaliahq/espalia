# frozen_string_literal: true

# Async RES handler that asks for placement suggestions when feedback is
# recorded, and again when its author edits it (the job supersedes the
# earlier set). Only human-authored feedback qualifies: events written by an
# HRIS sync or a system job carry no one's judgement worth placing. Self
# feedback does qualify: it is always placed, but one example often speaks to
# several capabilities. The job re-checks the tenant switch and the item, so a
# run enqueued before the switch went off does nothing.
#
# NOT a projection — it enqueues work that calls an outside service and must
# never be registered in Projections::Registry (replaying it would re-ask the
# model about every item ever recorded).
class PersonDevelopment::AsyncHandlers::PlacementSuggester < ApplicationJob
  prepend RailsEventStore::AsyncHandler

  NON_HUMAN_SURFACES = %w[hris system].freeze

  # @return [Array<Class>] events this handler subscribes to
  def self.handled_events
    [ PersonDevelopment::Events::EvidenceRecorded, PersonDevelopment::Events::EvidenceUpdated ]
  end

  # @param event [RubyEventStore::Event]
  def perform(event)
    return if NON_HUMAN_SURFACES.include?(event.metadata[:acting_via].to_s)

    tenant = Tenant.find_by(id: event.metadata[:tenant_id])
    return unless tenant&.evidence_suggestions_enabled?

    ActsAsTenant.with_tenant(tenant) do
      item = EvidenceItem.find_by(id: event.data[:evidence_id])
      next if item.nil?

      Evidence::SuggestPlacementsJob.perform_later(item.id)
    end
  end
end
