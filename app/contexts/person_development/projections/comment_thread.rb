# frozen_string_literal: true

# Synchronous projection that materialises comments on a person's
# development stream into the {PersonDevelopmentComment} read model.
#
# Subscribes to the three comment events and upserts/edits/soft-deletes
# rows. Broadcasts to the same `assessment_updates` Turbo channel as the
# other PD projections so the open assessment view reloads the activity
# feed (and the focused-cell comment thread) whenever a comment changes.
#
class PersonDevelopment::Projections::CommentThread
  PROJECTION_NAME = "person_development/comment_thread"
  # 2 — handles `FrameworkVersionMigrated`: re-keys assessment-cell
  #     comments onto the survivor `to_stable_id` for same/evolved
  #     mappings. archived/split leave the comment in place as
  #     historical context (no UI surfaces it because the archived
  #     capability doesn't render in the matrix).
  CODE_VERSION = 2

  # @return [Array<Class>] event classes this projection handles
  def self.handled_events
    [
      PersonDevelopment::Events::CommentPosted,
      PersonDevelopment::Events::CommentEdited,
      PersonDevelopment::Events::CommentDeleted,
      PersonDevelopment::Events::FrameworkVersionMigrated
    ]
  end

  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      PersonDevelopmentComment.where(tenant_id: tenant.id).delete_all
    end
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    with_tenant(event) do
      handle(event)
      broadcast_assessment_sync(event)
    end
  end

  private

  def handle(event)
    case event
    when PersonDevelopment::Events::FrameworkVersionMigrated then handle_framework_version_migrated(event)
    when PersonDevelopment::Events::CommentPosted  then handle_posted(event)
    when PersonDevelopment::Events::CommentEdited  then handle_edited(event)
    when PersonDevelopment::Events::CommentDeleted then handle_deleted(event)
    end
  end

  def handle_posted(event)
    # Idempotent for replay: keying by the event-supplied comment_id
    # means re-processing leaves the row in the same state rather than
    # raising RecordNotUnique.
    record = PersonDevelopmentComment.find_or_initialize_by(id: event.data[:comment_id])
    record.assign_attributes(
      tenant_id: event.metadata[:tenant_id],
      person_id: event.metadata[:person_id],
      framework_id: event.metadata[:framework_id],
      commentable_type: event.data[:commentable_type],
      capability_stable_id: event.data[:capability_stable_id],
      level_ordinal: event.data[:level_ordinal],
      parent_id: event.data[:parent_id],
      body: event.data[:body],
      author_id: event.data[:author_id],
      status: "active",
      posted_at: event.metadata[:timestamp] || Time.current
    )
    record.save!
  end

  def handle_edited(event)
    record = PersonDevelopmentComment.find_by(id: event.data[:comment_id])
    return unless record

    record.update!(
      body: event.data[:body],
      edited_at: event.metadata[:timestamp] || Time.current,
      edited_by_id: event.data[:edited_by_id]
    )
  end

  def handle_deleted(event)
    record = PersonDevelopmentComment.find_by(id: event.data[:comment_id])
    return unless record

    record.update!(
      status: "deleted",
      deleted_at: event.metadata[:timestamp] || Time.current,
      deleted_by_id: event.data[:deleted_by_id],
      deletion_reason: event.data[:reason]
    )
  end

  # Re-keys comments onto the survivor `to_stable_id` for `same`/`evolved`
  # mappings. `archived`/`split` comments are left in place as historical
  # context — they're invisible in the matrix because the parent
  # capability no longer renders, but they still exist for forensic
  # lookup. `new` is a no-op.
  def handle_framework_version_migrated(event)
    person_id = event.metadata[:person_id]
    framework_id = event.data[:framework_id]

    event.data[:mappings].each do |mapping|
      next unless %w[same evolved].include?(mapping[:mapping_type])
      next if mapping[:to_stable_id].nil?

      PersonDevelopmentComment.where(
        person_id: person_id, framework_id: framework_id,
        capability_stable_id: mapping[:from_stable_id]
      ).update_all(capability_stable_id: mapping[:to_stable_id])
    end
  end

  # Suppressed during replay (see `Projections::Replayer.replay_mode?`).
  def broadcast_assessment_sync(event)
    return if Projections::Replayer.replay_mode?

    Turbo::StreamsChannel.broadcast_replace_to(
      "assessment_updates", event.metadata[:framework_id], event.metadata[:person_id],
      target: "assessment-sync-signal",
      html: "<div id=\"assessment-sync-signal\" class=\"hidden\" data-assessment-sync-target=\"signal\" data-updated-at=\"#{Time.current.to_f}\"></div>"
    )
  rescue => e
    Rails.logger.warn("[CommentThread] Broadcast failed: #{e.message}")
  end

  def with_tenant(event, &block)
    tenant = Tenant.find(event.metadata[:tenant_id])
    ActsAsTenant.with_tenant(tenant, &block)
  end
end
