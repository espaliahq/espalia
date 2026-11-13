# frozen_string_literal: true

# Async RES handler that turns a posted assessment comment (cell thread or
# evidence-linkage thread) into notifications for the conversation's other
# parties:
#
#   reply                        → the parent comment's author
#   comment by anyone ≠ assessee → the assessee
#   comment by the assessee      → the manager side (recorded reporting
#                                  manager + active rating delegates)
#
# One notification per recipient per comment: a recipient matching several
# rules gets only the most specific one (reply beats the generic kinds), and
# the comment's author is never notified of their own comment. Edits and
# deletes stay silent — the thread shows them; a ping for an edit is noise.
#
# Recipients are by construction inside the comment-visibility set
# ({PersonDevelopmentCommentPolicy}): the assessee, the manager side, and
# thread participants. Peer evidence authors are excluded from linkage
# threads upstream, so they can never surface as a parent author here.
#
# Runs via SolidQueue (prepended AsyncHandler). NOT a projection — it
# dispatches side effects and must never be registered in
# Projections::Registry (replaying it would re-send notifications).
class PersonDevelopment::AsyncHandlers::CommentNotifier < ApplicationJob
  prepend RailsEventStore::AsyncHandler
  include PersonDevelopment::AsyncHandlers::AssessmentNotificationRecipients

  # @return [Array<Class>] events this handler subscribes to
  def self.handled_events
    [ PersonDevelopment::Events::CommentPosted ]
  end

  # @param event [RubyEventStore::Event]
  def perform(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      comment = PersonDevelopmentComment.find_by(id: event.data[:comment_id])
      next if comment.nil?

      notify_recipients(comment)
    end
  end

  private

  def notify_recipients(comment)
    feedback_author = evidence_author(comment)
    context = context_line(comment, feedback_author.last)
    url = deep_link(comment)
    notified = [ comment.author_id ]

    parent_author = parent_author_id(comment)
    if parent_author.present? && notified.exclude?(parent_author)
      deliver(CommentReplyNotifier, comment, parent_author, context, feedback_author, url)
      notified << parent_author
    end

    if notified.exclude?(comment.person_id)
      deliver(AssessmentCommentedNotifier, comment, comment.person_id, context, feedback_author, url)
      notified << comment.person_id
    end

    return unless comment.author_id == comment.person_id

    manager_side_ids_for(comment.person_id, comment.framework_id).each do |person_id|
      next if notified.include?(person_id)

      deliver(TeamAssessmentCommentedNotifier, comment, person_id, context, feedback_author, url)
      notified << person_id
    end
  end

  # One author read feeds the context line and its id/name params, so an
  # erasure between two reads can't leave the context naming them unmarked.
  def deliver(notifier_class, comment, person_id, context, feedback_author, url)
    user = user_for(person_id)
    return if user.nil?
    return if already_delivered?(notifier_class, user, comment)

    feedback_author_id, feedback_author_name = feedback_author

    notifier_class.with(
      record: comment,
      tenant_id: comment.tenant_id,
      author_id: comment.author_id,
      author_name: comment.author&.name,
      body: comment.body,
      context: context,
      feedback_author_id: feedback_author_id,
      feedback_author_name: feedback_author_name,
      url: url,
      comment_id: comment.id
    ).deliver(user)
  end

  # @return [String, nil] the author of the comment this one replies to
  def parent_author_id(comment)
    return nil if comment.parent_id.nil?

    comment.parent&.author_id
  end

  # Where in the assessment the conversation lives — "«Capability» · L«n»",
  # prefixed with whose feedback is being discussed for a linkage thread.
  #
  # @return [String, nil]
  def context_line(comment, feedback_author)
    parts = []
    parts << "#{feedback_author}'s feedback" if feedback_author
    parts << [ capability_name(comment), "L#{comment.level_ordinal}" ].compact.join(" · ")
    parts.join(" · ").presence
  end

  # @return [String] the assessment cell the thread hangs off, focused via the
  #   existing `?capability=` + `?level_ordinal=` deep-link params. The same
  #   path renders self or manager context per viewer.
  def deep_link(comment)
    assessment_cell_path(comment.person_id, comment.framework_id,
      capability_stable_id: comment.capability_stable_id, level_ordinal: comment.level_ordinal)
  end

  # The name opens the context line, and the id beside it lets forgetting
  # the author find it.
  #
  # @return [Array(String, String), Array()] the evidence author's id and name
  def evidence_author(comment)
    return [] if comment.evidence_id.nil?

    Person.where(id: EvidenceItem.where(id: comment.evidence_id).select(:author_id)).pick(:id, :name) || []
  end

  def capability_name(comment)
    capability_name_for(comment.capability_stable_id, comment.framework_id)
  end

  # @return [User, nil] the User behind a person, provisioning one lazily so
  #   the notification reaches an HRIS-imported person who has never logged in.
end
