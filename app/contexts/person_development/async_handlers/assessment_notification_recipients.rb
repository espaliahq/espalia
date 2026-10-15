# frozen_string_literal: true

# The recipient plumbing every assessment-side notifier shares: who the
# manager side of an assessment is, and whether a (recipient, type, record)
# notification already went out — RES async handlers run at-least-once, so a
# retried job after a partial fan-out must not re-notify anyone.
module PersonDevelopment::AsyncHandlers::AssessmentNotificationRecipients
  private

  # The recorded reporting manager (falling back to the live org chart when
  # nothing is recorded yet) plus active rating delegates.
  #
  # @return [Array<String>] person ids
  def manager_side_ids_for(person_id, framework_id)
    manager_id = RecordedReportingManager.manager_id_for(person_id, framework_id) ||
                 Person.where(id: person_id).pick(:manager_id)
    delegate_ids = ManagerAssessmentDelegation.active
      .for_person(person_id)
      .for_framework(framework_id)
      .pluck(:delegate_person_id)

    ([ manager_id ] + delegate_ids).compact.uniq
  end

  # The Noticed event's polymorphic `record` keys the persisted dedup check.
  #
  # @return [Boolean]
  def already_delivered?(notifier_class, user, record)
    Noticed::Notification
      .where(recipient: user)
      .joins(:event)
      .where(noticed_events: { type: notifier_class.name, record_type: record.class.name, record_id: record.id })
      .exists?
  end

  # @return [User, nil] provisioned on first contact so a person who has never
  #   signed in still receives the notification
  def user_for(person_id)
    Person.find_by(id: person_id)&.ensure_user!
  end
end
