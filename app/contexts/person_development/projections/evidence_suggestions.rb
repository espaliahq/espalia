# frozen_string_literal: true

# Writes {EvidencePlacementSuggestion} rows from the suggestion events on the
# person's development stream: one row per suggestion, keyed by its
# `suggestion_id`, so a rebuild keeps every id the hub and MCP clients hold.
#
# Accepting writes no suggestion event. A link event that carries
# `via_suggestion_id` decides the row: `accepted`, or `edited` when the link's
# valence differs from the one suggested. A decision is final, as on the
# aggregate.
#
# The Org Graph's `PersonForgotten` closes the person's pending rows, so they
# leave every screen. The aggregate still holds them as pending, and
# {PersonDevelopment::SuggestionWrites} refuses every command on a forgotten
# person, so the two never disagree about a write
# ([#590](https://github.com/espaliahq/espalia/issues/590)).
class PersonDevelopment::Projections::EvidenceSuggestions
  PROJECTION_NAME = "person_development/evidence_suggestions"
  # 2: closes a forgotten person's pending rows, including those forgotten before,
  # and keeps, closed, the rows of theirs that no event records.
  CODE_VERSION = 2

  # @return [Array<Class>] event classes this projection handles
  def self.handled_events
    [
      PersonDevelopment::Events::EvidencePlacementSuggested,
      PersonDevelopment::Events::EvidencePlacementSuggestionsSuperseded,
      PersonDevelopment::Events::EvidencePlacementSuggestionDismissed,
      PersonDevelopment::Events::EvidenceLinkAdded,
      PersonDevelopment::Events::EvidenceLinkRevalenced,
      PersonDevelopment::Events::FrameworkVersionMigrated,
      OrgGraph::Events::PersonForgotten
    ]
  end

  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      kept = unrecorded_forgotten_rows
      EvidencePlacementSuggestion.where(tenant_id: tenant.id).where.not(id: kept).delete_all
      EvidencePlacementSuggestion.pending.where(id: kept).update_all(status: "closed", updated_at: Time.current)
    end
  end

  # The catch-up that put the table's rows on the streams skipped forgotten
  # people, so a row of someone forgotten before it may have no event to
  # rebuild it from. A rebuild keeps such a row, closed, rather than lose it.
  #
  # @return [Array<String>] suggestion ids
  def self.unrecorded_forgotten_rows
    rows = EvidencePlacementSuggestion.where(person_id: Person.forgotten.select(:id)).pluck(:id, :person_id, :framework_id)
    rows.group_by { it.drop(1) }.flat_map do |(person_id, framework_id), group|
      stream = EventStreamNaming.person_development_stream(person_id, framework_id)
      recorded = Rails.configuration.event_store.read.stream(stream)
        .of_type([ PersonDevelopment::Events::EvidencePlacementSuggested ]).map { it.data[:suggestion_id] }
      group.map(&:first) - recorded
    end
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) { handle(event) }
    broadcast_assessment_sync(event) if event.is_a?(PersonDevelopment::Events::EvidencePlacementSuggestionDismissed)
  end

  private

  def handle(event)
    case event
    when PersonDevelopment::Events::EvidencePlacementSuggested then handle_suggested(event)
    when PersonDevelopment::Events::EvidencePlacementSuggestionsSuperseded then handle_superseded(event)
    when PersonDevelopment::Events::EvidencePlacementSuggestionDismissed then handle_dismissed(event)
    when PersonDevelopment::Events::EvidenceLinkAdded then handle_link(event, event.data[:linked_by_id])
    when PersonDevelopment::Events::EvidenceLinkRevalenced then handle_link(event, event.data[:changed_by_id])
    when PersonDevelopment::Events::FrameworkVersionMigrated then handle_framework_version_migrated(event)
    when OrgGraph::Events::PersonForgotten then handle_forgotten(event)
    end
  end

  # A new suggestion, or a superseded one the model proposed again. An
  # `already_held` event carries the status the table held when it was
  # recorded, and who decided it.
  def handle_suggested(event)
    data = event.data
    row = EvidencePlacementSuggestion.find_or_initialize_by(id: data[:suggestion_id])
    return if row.persisted? && (EvidencePlacementSuggestion::DECIDED_STATUSES + %w[closed]).include?(row.status)

    row.assign_attributes(
      evidence_id: data[:evidence_id], person_id: event.metadata[:person_id], framework_id: event.metadata[:framework_id],
      capability_stable_id: data[:capability_stable_id], level_ordinal: data[:level_ordinal],
      valence: data[:valence], confidence: data[:confidence], rationale: data[:rationale],
      provider: data[:provider], model: data[:model], prompt_version: data[:prompt_version], generated_at: data[:generated_at],
      status: data[:status] || "pending", decided_by_id: data[:decided_by_id], decided_at: data[:decided_at], dismiss_reason: nil
    )
    row.save!
  end

  def handle_superseded(event)
    EvidencePlacementSuggestion.pending.where(id: Array(event.data[:suggestion_ids]))
      .update_all(status: "superseded", updated_at: Time.current)
  end

  def handle_forgotten(event)
    EvidencePlacementSuggestion.pending.where(person_id: event.data[:person_id])
      .update_all(status: "closed", updated_at: Time.current)
  end

  def handle_dismissed(event)
    EvidencePlacementSuggestion.pending.where(id: event.data[:suggestion_id]).update_all(
      status: "dismissed", decided_by_id: event.data[:dismissed_by_id], decided_at: event.data[:dismissed_at],
      dismiss_reason: event.data[:reason].presence, updated_at: Time.current
    )
  end

  def handle_link(event, decided_by_id)
    row = event.data[:via_suggestion_id] && EvidencePlacementSuggestion.pending.find_by(id: event.data[:via_suggestion_id])
    return unless row

    row.update!(status: event.data[:valence] == row.valence ? "accepted" : "edited",
                decided_by_id: decided_by_id, decided_at: event.metadata[:timestamp] || Time.current)
  end

  # Moves suggestions on a retiring capability onto its survivor, so a
  # dismissal keeps blocking the cell it was about. Where the item already has
  # a suggestion at the survivor's cell, {PersonDevelopment::SuggestionCollision}
  # picks the one that stays, as the aggregate does. A suggestion on an archived
  # or split capability is left as it is; accepting it is refused, as its cell
  # is gone.
  def handle_framework_version_migrated(event)
    event.data[:mappings].each do |mapping|
      to_stable_id = mapping[:to_stable_id]
      next unless %w[same evolved].include?(mapping[:mapping_type])
      next if to_stable_id.nil? || to_stable_id == mapping[:from_stable_id]

      EvidencePlacementSuggestion.where(person_id: event.metadata[:person_id], framework_id: event.data[:framework_id],
                                        capability_stable_id: mapping[:from_stable_id]).find_each do |retiring|
        rekey(retiring, to_stable_id)
      end
    end
  end

  def rekey(retiring, to_stable_id)
    survivor = EvidencePlacementSuggestion.find_by(evidence_id: retiring.evidence_id, level_ordinal: retiring.level_ordinal,
                                                   capability_stable_id: to_stable_id)
    case PersonDevelopment::SuggestionCollision.resolve(retiring: retiring.status, survivor: survivor&.status)
    when :move then retiring.update!(capability_stable_id: to_stable_id)
    when :keep_survivor then retiring.destroy!
    when :replace_survivor
      survivor.destroy!
      retiring.update!(capability_stable_id: to_stable_id)
    end
  end

  # A dismissal shows in the activity feed, and nothing else nudges the open
  # assessment about it. The link events are {EvidenceCollection}'s to announce.
  def broadcast_assessment_sync(event)
    return if Projections::Replayer.replay_mode?

    Turbo::StreamsChannel.broadcast_replace_to(
      "assessment_updates", event.metadata[:framework_id], event.metadata[:person_id],
      target: "assessment-sync-signal",
      html: "<div id=\"assessment-sync-signal\" class=\"hidden\" data-assessment-sync-target=\"signal\" data-updated-at=\"#{Time.current.to_f}\"></div>"
    )
  rescue => e
    Rails.logger.warn("[EvidenceSuggestions] Broadcast failed: #{e.message}")
  end
end
