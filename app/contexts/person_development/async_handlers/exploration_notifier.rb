# frozen_string_literal: true

# Async RES handler that tells the other party when a declared exploration
# (ADR-22) starts or closes — declaring is the act the other party is meant
# to see (looking through a lens tells nobody):
#
#   declared / closed by the assessee → the manager side (recorded reporting
#                                       manager + active rating delegates)
#   declared / closed by anyone else  → the assessee, and the reporting
#                                       manager when a delegate acted
#   closed by nobody (a move into the  → both
#   explored role closed it)
#
# The actor is never notified of their own act.
#
# Runs via SolidQueue (prepended AsyncHandler). NOT a projection — it
# dispatches side effects and must never be registered in
# Projections::Registry (replaying it would re-send notifications).
class PersonDevelopment::AsyncHandlers::ExplorationNotifier < ApplicationJob
  prepend RailsEventStore::AsyncHandler

  NOTIFIERS = {
    PersonDevelopment::Events::ExplorationStarted => "ExplorationStartedNotifier",
    PersonDevelopment::Events::ExplorationClosed => "ExplorationClosedNotifier"
  }.freeze

  # @return [Array<Class>] events this handler subscribes to
  def self.handled_events
    NOTIFIERS.keys
  end

  # @param event [RubyEventStore::Event]
  def perform(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      exploration = AssessmentExploration.find_by(id: event.data[:exploration_id])
      next if exploration.nil?

      notify(event, exploration)
    end
  end

  private

  def notify(event, exploration)
    actor_id = event.data[:started_by_id] || event.data[:closed_by_id]
    notifier = NOTIFIERS.fetch(event.class).constantize
    params = {
      tenant_id: event.metadata[:tenant_id],
      actor_name: Person.where(id: actor_id).pick(:name),
      by_assessee: actor_id == exploration.person_id,
      assessee_name: Person.where(id: exploration.person_id).pick(:name),
      role_label: exploration.label,
      outcome: event.data[:outcome],
      note: event.data[:note],
      url: deep_link(exploration),
      exploration_event_id: event.event_id
    }

    (recipient_ids(exploration, actor_id) - [ actor_id ]).each do |person_id|
      user = Person.find_by(id: person_id)&.ensure_user!
      next if user.nil? || already_delivered?(notifier, user, event)

      notifier.with(params.merge(to_assessee: person_id == exploration.person_id)).deliver(user)
    end
  end

  # @return [Array<String>]
  def recipient_ids(exploration, actor_id)
    return [ exploration.person_id ] + manager_side_ids(exploration) if actor_id.nil?
    return manager_side_ids(exploration) if actor_id == exploration.person_id

    [ exploration.person_id, reporting_manager_id(exploration) ].compact
  end

  # @return [String, nil]
  def reporting_manager_id(exploration)
    RecordedReportingManager.manager_id_for(exploration.person_id, exploration.framework_id) ||
      Person.where(id: exploration.person_id).pick(:manager_id)
  end

  # The recorded reporting manager (live org chart fallback) plus active
  # rating delegates — the manager side of the conversation.
  #
  # @return [Array<String>]
  def manager_side_ids(exploration)
    manager_id = reporting_manager_id(exploration)
    delegate_ids = ManagerAssessmentDelegation.active
      .for_person(exploration.person_id).for_framework(exploration.framework_id)
      .pluck(:delegate_person_id)
    ([ manager_id ] + delegate_ids).compact.uniq
  end

  # RES async handlers run at-least-once — a retried job must not re-ping.
  def already_delivered?(notifier, user, event)
    Noticed::Notification.where(recipient: user).joins(:event)
      .where(noticed_events: { type: notifier.name })
      .where("noticed_events.params::text LIKE ?", "%#{event.event_id}%")
      .exists?
  end

  def deep_link(exploration)
    assignment_id = PersonFrameworkAssignment
      .where(person_id: exploration.person_id, framework_id: exploration.framework_id).pick(:id)
    return "/assessments" if assignment_id.nil?

    "/assessments/#{assignment_id}?" \
      "#{{ as_role: exploration.target_role_id, as_level: exploration.target_level_ordinal }.compact.to_query}"
  end
end
