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
# EvidenceRequestNotifier already tells them it was answered. An unplaced
# item's copy asks the recipient to place it and links to the assessment,
# whose feed shows it; a placed item links to its cell.
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

      notify_recipients(item)
    end
  end

  private

  def notify_recipients(item)
    params = presentation(item)
    skipped = [ item.author_id, *answered_requester_ids(item) ]

    unless skipped.include?(item.person_id)
      deliver(FeedbackReceivedNotifier, item, item.person_id, params)
      skipped << item.person_id
    end

    manager_side_ids_for(item.person_id, item.framework_id).each do |person_id|
      next if skipped.include?(person_id)

      deliver(TeamFeedbackReceivedNotifier, item, person_id, params)
      skipped << person_id
    end
  end

  def deliver(notifier_class, item, person_id, params)
    user = user_for(person_id)
    return if user.nil?
    return if already_delivered?(notifier_class, user, item)

    notifier_class.with(record: item, tenant_id: item.tenant_id, **params).deliver(user)
  end

  def presentation(item)
    link = first_link(item)
    {
      author_name: item.author&.name,
      assessee_name: Person.where(id: item.person_id).pick(:name),
      placed: link.present?,
      context: link ? cell_label(item, link) : "Not yet placed on a capability — place it to show it on the assessment",
      content: item.content,
      url: assessment_path(item, link)
    }
  end

  # Whoever asked the author for feedback that this item answers: the request
  # it is recorded against once the response is projected, or — because that
  # projection can land a moment after this runs — a request to the author
  # still pending on the very cell the item was placed on. A pending request
  # on another cell is unrelated, and its requester is told like anyone else.
  def answered_requester_ids(item)
    scope = EvidenceRequest.for_assessment(item.person_id, item.framework_id)
    answered = scope.where(evidence_id: item.id)
    link = first_link(item)
    if link
      answered = answered.or(scope.pending.where(requestee_person_id: item.author_id,
        capability_stable_id: link.capability_stable_id, level_ordinal: link.level_ordinal))
    end
    answered.pluck(:requested_by_id)
  end

  def first_link(item)
    return @first_link if defined?(@first_link)

    @first_link = EvidenceLink.active.where(evidence_id: item.id).order(:linked_at).first
  end

  def cell_label(item, link)
    name = FrameworkState::Capability
      .joins(:category)
      .where(stable_id: link.capability_stable_id)
      .merge(FrameworkState::CapabilityCategory.where(framework_id: item.framework_id))
      .pick(:name)
    [ name, "L#{link.level_ordinal}" ].compact.join(" · ")
  end

  # The assessment, focused on the item's first cell through the existing
  # deep-link params when it has one; the same path renders self or manager
  # context per viewer, and its feed carries an unplaced item.
  def assessment_path(item, link)
    assignment_id = PersonFrameworkAssignment.where(person_id: item.person_id, framework_id: item.framework_id).pick(:id)
    return "/assessments" if assignment_id.nil?
    return "/assessments/#{assignment_id}" if link.nil?

    "/assessments/#{assignment_id}?capability=#{link.capability_stable_id}&level_ordinal=#{link.level_ordinal}"
  end
end
