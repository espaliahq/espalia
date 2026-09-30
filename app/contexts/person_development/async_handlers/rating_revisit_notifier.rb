# frozen_string_literal: true

# Async RES handler that turns a calibration rating-revisit request (the
# PD-stream mirror event) into a notification for the rater being asked —
# in-app + Slack per their preferences, with the room's note quoted so the
# nudge reads without a round trip.
#
# Dropped when the ask has already been acted on by the time the job runs
# (the manager rating for the cell changed after the request — the same
# rating-change-based resolution the session log uses), and when the rater
# is the person who asked (no self-pings).
#
# Runs via SolidQueue (prepended AsyncHandler). NOT a projection — it
# dispatches side effects and must never be registered in
# Projections::Registry (replaying it would re-send notifications).
class PersonDevelopment::AsyncHandlers::RatingRevisitNotifier < ApplicationJob
  prepend RailsEventStore::AsyncHandler

  # @return [Array<Class>] events this handler subscribes to
  def self.handled_events
    [ PersonDevelopment::Events::RatingRevisitRequested ]
  end

  # @param event [RubyEventStore::Event]
  def perform(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      notify(event)
    end
  end

  private

  def notify(event) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    data = event.data
    person_id = event.metadata[:person_id]
    framework_id = event.metadata[:framework_id]
    return if person_id.nil? || framework_id.nil?
    return if data[:rater_id] == data[:requested_by_id]
    return if already_delivered?(event)
    return if already_acted?(event, person_id, framework_id)

    user = user_for(data[:rater_id])
    return if user.nil?

    RatingRevisitRequestedNotifier.with(
      tenant_id: event.metadata[:tenant_id],
      requested_by_name: person_name(data[:requested_by_id]),
      assessee_name: person_name(person_id),
      context: context_line(data, framework_id),
      note: data[:note],
      url: deep_link(person_id, framework_id, data),
      revisit_event_id: event.event_id
    ).deliver(user)
  end

  # RES async handlers run at-least-once — a retried job must not re-ping.
  # The originating event id rides the Noticed params; params are stored
  # through ActiveJob serialization, so match on the jsonb text (the id is
  # a UUID — collision-safe) rather than assuming the serialized key shape.
  #
  # @return [Boolean]
  def already_delivered?(event)
    Noticed::Event
      .where(type: "RatingRevisitRequestedNotifier")
      .where("params::text LIKE ?", "%#{event.event_id}%")
      .exists?
  end

  # Whether the manager rating for the cell already changed after the ask —
  # the request is then settled and a ping would chase a done deed.
  # Scoped to the asking session's cycle (rating rows are one-per-cycle):
  # a later cycle's seeded carry-forward stamps last_manager_rated_at too
  # and must not suppress the ping, nor may a stale prior-cycle row force it.
  #
  # @return [Boolean]
  def already_acted?(event, person_id, framework_id)
    requested_at = event.metadata[:timestamp]
    return false if requested_at.nil?

    scope = AssessmentLevelRating.across_all_roles.where(
      person_id: person_id, framework_id: framework_id,
      capability_stable_id: event.data[:capability_stable_id],
      level_ordinal: event.data[:level_ordinal]
    )
    cycle_id = CalibrationSession.where(id: event.data[:calibration_session_id]).pick(:cycle_id)
    scope = scope.where(cycle_id: cycle_id) if cycle_id

    rated_at = scope.maximum(:last_manager_rated_at)
    rated_at.present? && rated_at > requested_at
  end

  # "«Session» · «Capability» · L«n»" — where the conversation happened and
  # which cell it concerns.
  #
  # @return [String, nil]
  def context_line(data, framework_id)
    [
      data[:session_name].presence,
      [ capability_name(data[:capability_stable_id], framework_id),
        "L#{data[:level_ordinal]}" ].compact.join(" · ")
    ].compact.join(" · ").presence
  end

  # @return [String] the assessment cell, focused via the existing
  #   `?capability=` + `?level_ordinal=` deep-link params (renders the
  #   manager view for the rater).
  def deep_link(person_id, framework_id, data)
    assignment_id = PersonFrameworkAssignment
      .where(person_id: person_id, framework_id: framework_id)
      .pick(:id)
    return "/assessments" if assignment_id.nil?

    "/assessments/#{assignment_id}?capability=#{data[:capability_stable_id]}&level_ordinal=#{data[:level_ordinal]}"
  end

  def capability_name(stable_id, framework_id)
    FrameworkState::Capability
      .joins(:category)
      .where(stable_id: stable_id)
      .merge(FrameworkState::CapabilityCategory.where(framework_id: framework_id))
      .first&.name
  end

  def person_name(person_id)
    Person.where(id: person_id).pick(:name)
  end

  # @return [User, nil] the User behind a person, provisioning one lazily so
  #   the notification reaches an HRIS-imported rater who has never logged in.
  def user_for(person_id)
    Person.find_by(id: person_id)&.ensure_user!
  end
end
