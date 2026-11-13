# frozen_string_literal: true

# Async RES handler that tells the people an assessment is about that
# feedback was recorded on it:
#
#   feedback by anyone ≠ assessee → the assessee
#   feedback by anyone            → the manager side (recorded reporting
#                                   manager + active rating delegates)
#
# The author is never told about their own feedback, self feedback tells
# nobody, and the requester of a request this item answers is left out —
# EvidenceRequestNotifier already tells them it was answered (the response's
# event names its request, so this never waits on the request's projection).
# An unplaced item's copy asks the recipient to place it and links to its card
# on the hub, where placing happens; a placed item links to its cell.
#
# Feedback imported from a peer system (`acting_via: feedback_exchange`) tells
# nobody: the system it was given in owns its notifications. It surfaces on
# the hub under "Feedback to place".
#
# Runs via SolidQueue (prepended AsyncHandler). NOT a projection — it
# dispatches side effects and must never be registered in
# Projections::Registry (replaying it would re-send notifications).
class PersonDevelopment::AsyncHandlers::FeedbackNotifier < ApplicationJob
  prepend RailsEventStore::AsyncHandler
  include PersonDevelopment::AsyncHandlers::AssessmentNotificationRecipients

  # @return [Array<Class>] events this handler subscribes to
  def self.handled_events
    [ PersonDevelopment::Events::EvidenceRecorded ]
  end

  # @param event [RubyEventStore::Event]
  def perform(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      item = EvidenceItem.find_by(id: event.data[:evidence_id])
      next if item.nil? || item.source == "self"

      next if event.metadata[:acting_via].to_s == "feedback_exchange"

      notify_recipients(item, event.data[:request_id])
    end
  end

  private

  def notify_recipients(item, request_id)
    params = presentation(item)
    skipped = [ item.author_id, *answered_requester_ids(item, request_id) ]

    unless skipped.include?(item.person_id)
      deliver(FeedbackReceivedNotifier, item, item.person_id, params)
      skipped << item.person_id
    end

    manager_side_ids_for(item.person_id, item.framework_id).each do |person_id|
      next if skipped.include?(person_id)

      deliver(TeamFeedbackReceivedNotifier, item, person_id, params.merge(url: manager_side_url(item, person_id, params)))
      skipped << person_id
    end
  end

  def deliver(notifier_class, item, person_id, params)
    user = user_for(person_id)
    return if user.nil?
    return if already_delivered?(notifier_class, user, item)

    notifier_class.with(record: item, tenant_id: item.tenant_id, **params).deliver(user)
  end

  # The hub lists a report's unplaced item in its team view by default; a
  # recorded reporting manager who is now a skip-level sees it only in the
  # org view, so their link opens that view.
  def manager_side_url(item, person_id, params)
    return params[:url] if params[:placed]

    viewer = Person.find_by(id: person_id)
    viewer ? Assessments::FeedbackToPlace.new(viewer).hub_path(item) : params[:url]
  end

  def presentation(item)
    link = first_link(item)
    {
      author_id: item.author_id,
      author_name: item.author&.name,
      assessee_id: item.person_id,
      assessee_name: Person.where(id: item.person_id).pick(:name),
      placed: link.present?,
      context: link ? cell_label(item, link) : "Not yet placed on a capability — place it to show it on the assessment",
      content: item.content,
      url: link ? assessment_path(item, link) : EvidenceItem.hub_path(item.id)
    }
  end

  # Whoever asked for the feedback this item answers. The event names the
  # request it responds to (record_evidence_for_request), so this never
  # depends on the request's own event having been projected first — the
  # two publish together, but this job can run between them. Ordinary
  # feedback on a cell someone happens to have asked about tells them like
  # anyone else.
  def answered_requester_ids(item, request_id)
    scope = EvidenceRequest.for_assessment(item.person_id, item.framework_id)
    scope.where(evidence_id: item.id).or(scope.where(id: request_id)).pluck(:requested_by_id)
  end

  def first_link(item)
    return @first_link if defined?(@first_link)

    @first_link = EvidenceLink.active.where(evidence_id: item.id).order(:linked_at).first
  end

  def cell_label(item, link)
    [ capability_name_for(link.capability_stable_id, item.framework_id), "L#{link.level_ordinal}" ].compact.join(" · ")
  end

  def assessment_path(item, link)
    assessment_cell_path(item.person_id, item.framework_id,
      capability_stable_id: link.capability_stable_id, level_ordinal: link.level_ordinal)
  end
end
