# frozen_string_literal: true

# Async RES handler that tells the assessee when their manager starts
# alignment against a role other than their home role (ADR-22) — the one act
# that discloses the manager's ratings on that role's cells. A start against
# the home role sends nothing: the assessee's own page already reads as the
# alignment conversation.
#
# Runs via SolidQueue (prepended AsyncHandler). NOT a projection — it
# dispatches side effects and must never be registered in
# Projections::Registry (replaying it would re-send notifications).
class PersonDevelopment::AsyncHandlers::LensAlignmentNotifier < ApplicationJob
  prepend RailsEventStore::AsyncHandler

  # @return [Array<Class>] events this handler subscribes to
  def self.handled_events
    [ PersonDevelopment::Events::AlignmentStarted ]
  end

  # @param event [RubyEventStore::Event]
  def perform(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      notify(event)
    end
  end

  private

  def notify(event)
    person_id = event.metadata[:person_id]
    role_id = event.data[:role_id]
    return if role_id.nil? || person_id.nil?

    row = AssessmentCycleRoleAlignment.find_by(cycle_id: event.data[:cycle_id], person_id: person_id, role_id: role_id)
    return if row.nil? || row.home
    return if already_delivered?(event)

    role = FrameworkState::Role.find_by(role_id: role_id)
    user = Person.find_by(id: person_id)&.ensure_user!
    return if role.nil? || user.nil?

    code = "#{role.code}#{row.level_ordinal}"
    LensAlignmentStartedNotifier.with(
      tenant_id: event.metadata[:tenant_id],
      started_by_name: Person.where(id: event.data[:started_by_id]).pick(:name),
      role_label: "#{role.name} · #{code}",
      role_code: code,
      home_code: home_code(event.data[:cycle_id], person_id),
      url: deep_link(person_id, event.metadata[:framework_id], role_id, row.level_ordinal),
      alignment_event_id: event.event_id
    ).deliver(user)
  end

  # RES async handlers run at-least-once — a retried job must not re-ping.
  def already_delivered?(event)
    Noticed::Event
      .where(type: "LensAlignmentStartedNotifier")
      .where("params::text LIKE ?", "%#{event.event_id}%")
      .exists?
  end

  # "E3" — the record the lens leaves unchanged.
  def home_code(cycle_id, person_id)
    enrollment = AssessmentCycleEnrollment.find_by(cycle_id: cycle_id, person_id: person_id)
    code = FrameworkState::Role.where(role_id: enrollment&.role_id).pick(:code)
    code && enrollment.level_ordinal ? "#{code}#{enrollment.level_ordinal}" : "home"
  end

  def deep_link(person_id, framework_id, role_id, level_ordinal)
    assignment_id = PersonFrameworkAssignment.where(person_id: person_id, framework_id: framework_id).pick(:id)
    return "/assessments" if assignment_id.nil?

    "/assessments/#{assignment_id}?#{{ as_role: role_id, as_level: level_ordinal }.compact.to_query}"
  end
end
