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
# item's copy asks the recipient to place it and links to the hub, where
# placing happens; a placed item links to its cell.
#
# Runs via SolidQueue (prepended AsyncHandler). NOT a projection — it
# dispatches side effects and must never be registered in
# Projections::Registry (replaying it would re-send notifications).
class PersonDevelopment::AsyncHandlers::FeedbackNotifier < ApplicationJob
  prepend RailsEventStore::AsyncHandler

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

    manager_side_ids(item).each do |person_id|
      next if skipped.include?(person_id)

      deliver(TeamFeedbackReceivedNotifier, item, person_id, params)
      skipped << person_id
    end
  end

  def deliver(notifier_class, item, person_id, params)
    user = Person.find_by(id: person_id)&.ensure_user!
    return if user.nil?
    return if already_delivered?(notifier_class, user, item)

    notifier_class.with(record: item, tenant_id: item.tenant_id, **params).deliver(user)
  end

  # RES async handlers run at-least-once; the Noticed event's polymorphic
  # `record` keys the dedup check per (recipient, type, item) so a retried
  # job never re-notifies anyone.
  def already_delivered?(notifier_class, user, item)
    Noticed::Notification
      .where(recipient: user)
      .joins(:event)
      .where(noticed_events: { type: notifier_class.name, record_type: "EvidenceItem", record_id: item.id })
      .exists?
  end

  def presentation(item)
    placed = !item.unplaced?
    {
      author_name: item.author&.name,
      assessee_name: Person.where(id: item.person_id).pick(:name),
      placed: placed,
      context: placed ? cell_label(item) : "Not yet placed on a capability — place it to show it on the assessment",
      content: item.content,
      url: placed ? cell_path(item) : EvidenceItem.hub_path(item.id)
    }
  end

  # Whoever asked the author for feedback on this assessment: the request
  # this item answered once it is projected, and any request from the author
  # still pending — the response may be projected a moment after this runs.
  def answered_requester_ids(item)
    EvidenceRequest
      .for_assessment(item.person_id, item.framework_id)
      .where(evidence_id: item.id)
      .or(EvidenceRequest.for_assessment(item.person_id, item.framework_id).pending
        .where(requestee_person_id: item.author_id))
      .pluck(:requested_by_id)
  end

  def manager_side_ids(item)
    manager_id = RecordedReportingManager.manager_id_for(item.person_id, item.framework_id) ||
                 Person.where(id: item.person_id).pick(:manager_id)
    delegate_ids = ManagerAssessmentDelegation.active
      .for_person(item.person_id)
      .for_framework(item.framework_id)
      .pluck(:delegate_person_id)

    ([ manager_id ] + delegate_ids).compact.uniq
  end

  def cell_label(item)
    link = EvidenceLink.active.where(evidence_id: item.id).order(:linked_at).first
    return nil if link.nil?

    name = FrameworkState::Capability
      .joins(:category)
      .where(stable_id: link.capability_stable_id)
      .merge(FrameworkState::CapabilityCategory.where(framework_id: item.framework_id))
      .pick(:name)
    [ name, "L#{link.level_ordinal}" ].compact.join(" · ")
  end

  # The item's first cell on the assessment, focused through the existing
  # deep-link params; the same path renders self or manager context per viewer.
  def cell_path(item)
    assignment_id = PersonFrameworkAssignment.where(person_id: item.person_id, framework_id: item.framework_id).pick(:id)
    link = EvidenceLink.active.where(evidence_id: item.id).order(:linked_at).first
    return EvidenceItem.hub_path(item.id) if assignment_id.nil? || link.nil?

    "/assessments/#{assignment_id}?capability=#{link.capability_stable_id}&level_ordinal=#{link.level_ordinal}"
  end
end
