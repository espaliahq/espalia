# frozen_string_literal: true

# Synchronous projection that materialises suggestion discussion-thread
# comments into the {FrameworkState::SuggestionComment} read model — the
# table's single writer.
#
# Nudges the per-framework `framework_activity` Turbo stream on every
# comment event (replay-guarded) so the context pane — the feed and any
# open suggestion card — reloads live for every edit-mode viewer,
# including the actor. Edits/deletes broadcast too even though only posts
# produce feed entries: an open thread must not show stale bodies.
#
class Frameworks::Projections::SuggestionThread
  include Frameworks::Projections::BroadcastsFrameworkActivity

  PROJECTION_NAME = "frameworks/suggestion_thread"
  CODE_VERSION = 1

  # @return [Array<Class>] event classes this projection handles
  def self.handled_events
    [
      Frameworks::Events::SuggestionCommented,
      Frameworks::Events::SuggestionCommentEdited,
      Frameworks::Events::SuggestionCommentDeleted
    ]
  end

  # Truncates the read model this projection writes, scoped to one tenant.
  # Idempotent.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      FrameworkState::SuggestionComment.where(tenant_id: tenant.id).delete_all
    end
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    with_tenant(event) do
      handle(event)
      broadcast_framework_activity(event)
    end
  end

  private

  def handle(event)
    case event
    when Frameworks::Events::SuggestionCommented       then handle_commented(event)
    when Frameworks::Events::SuggestionCommentEdited   then handle_edited(event)
    when Frameworks::Events::SuggestionCommentDeleted  then handle_deleted(event)
    end
  end

  def handle_commented(event)
    # Idempotent for replay: keying by the event-supplied comment_id means
    # re-processing leaves the row in the same state rather than raising
    # RecordNotUnique. A re-delivered create after the comment's delete has
    # been applied must NOT resurrect the tombstone — never downgrade an
    # existing "deleted" status.
    record = FrameworkState::SuggestionComment.find_or_initialize_by(id: event.data[:comment_id])
    record.assign_attributes(
      tenant_id: event.metadata[:tenant_id],
      framework_id: event.data[:framework_id],
      suggestion_id: event.data[:suggestion_id],
      parent_id: event.data[:parent_id],
      author_id: event.data[:author_id],
      body: event.data[:body],
      posted_at: event.metadata[:timestamp] || Time.current
    )
    record.status = "active" if record.new_record?
    record.save!
  end

  def handle_edited(event)
    record = FrameworkState::SuggestionComment.find_by(id: event.data[:comment_id])
    return unless record

    record.update!(
      body: event.data[:body],
      edited_at: event.metadata[:timestamp] || Time.current,
      edited_by_id: event.data[:edited_by_id]
    )
  end

  def handle_deleted(event)
    record = FrameworkState::SuggestionComment.find_by(id: event.data[:comment_id])
    return unless record

    record.update!(
      status: "deleted",
      deleted_at: event.metadata[:timestamp] || Time.current,
      deleted_by_id: event.data[:deleted_by_id],
      deletion_reason: event.data[:reason]
    )
  end

  # Sets tenant context from event metadata before touching read models.
  def with_tenant(event, &block)
    tenant = Tenant.find(event.metadata[:tenant_id])
    ActsAsTenant.with_tenant(tenant, &block)
  end

  # All three comment events carry framework_id in their payload — no
  # fallback lookup needed (unlike PublishedState's resolved-suggestion
  # events). Edits/deletes broadcast too even though only posts produce
  # feed entries: an open thread must not show stale bodies.
  #
  # @param event [RubyEventStore::Event]
  def broadcast_framework_activity(event)
    broadcast_framework_activity_signal(event.data[:framework_id])
  end
end
