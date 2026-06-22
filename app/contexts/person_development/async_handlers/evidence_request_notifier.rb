# frozen_string_literal: true

# Async RES handler that turns evidence-request lifecycle events into
# notifications (in-app + Slack, per the recipient's preferences).
#
#   EvidenceRequested          → notify the requestee ("you've been asked")
#   EvidenceRequestResponded   → notify the requester ("answered")
#   EvidenceRequestDeclined    → notify the requester ("declined")
#
# Runs via SolidQueue (prepended AsyncHandler). NOT a projection — it
# dispatches side effects and must never be registered in
# Projections::Registry (replaying it would re-send notifications).
class PersonDevelopment::AsyncHandlers::EvidenceRequestNotifier < ApplicationJob
  prepend RailsEventStore::AsyncHandler

  # @return [Array<Class>] events this handler subscribes to
  def self.handled_events
    [
      PersonDevelopment::Events::EvidenceRequested,
      PersonDevelopment::Events::EvidenceRequestResponded,
      PersonDevelopment::Events::EvidenceRequestDeclined
    ]
  end

  # @param event [RubyEventStore::Event]
  def perform(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      request = EvidenceRequest.find_by(id: event.data[:request_id])
      next if request.nil?

      case event
      when PersonDevelopment::Events::EvidenceRequested then notify_requested(request)
      when PersonDevelopment::Events::EvidenceRequestResponded then notify_responded(request, event)
      when PersonDevelopment::Events::EvidenceRequestDeclined then notify_declined(request, event)
      end
    end
  end

  private

  def notify_requested(request)
    user = user_for(request.requestee_person_id)
    return if user.nil?

    EvidenceRequestedNotifier.with(
      tenant_id: request.tenant_id,
      requester_name: request.requester&.name,
      assessee_name: regarding_assessee_name(request),
      capability_name: capability_name(request),
      message: request.message,
      request_id: request.id
    ).deliver(user)
  end

  # The assessee's name when the request is about someone other than the person
  # who made it (a manager asking on a report's behalf); nil when asking about
  # their own assessment, so the title omits a redundant "regarding <self>".
  def regarding_assessee_name(request)
    return nil if request.person_id == request.requested_by_id

    request.assessee&.name
  end

  def notify_responded(request, event)
    user = user_for(request.requested_by_id)
    return if user.nil?

    EvidenceRequestRespondedNotifier.with(
      tenant_id: request.tenant_id,
      request_id: request.id,
      responder_name: Person.find_by(id: event.data[:responded_by_id])&.name,
      capability_name: capability_name(request)
    ).deliver(user)
  end

  def notify_declined(request, event)
    user = user_for(request.requested_by_id)
    return if user.nil?

    EvidenceRequestDeclinedNotifier.with(
      tenant_id: request.tenant_id,
      request_id: request.id,
      decliner_name: Person.find_by(id: event.data[:declined_by_id])&.name,
      capability_name: capability_name(request),
      reason: event.data[:reason]
    ).deliver(user)
  end

  # @return [User, nil] the global User behind a person in the current tenant
  def user_for(person_id)
    Person.find_by(id: person_id)&.tenant_user&.user
  end

  def capability_name(request)
    FrameworkState::Capability
      .joins(:category)
      .where(stable_id: request.capability_stable_id)
      .merge(FrameworkState::CapabilityCategory.where(framework_id: request.framework_id))
      .first&.name
  end
end
