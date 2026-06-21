# frozen_string_literal: true

# Authorization for cell-scoped evidence requests.
#
# The record is a {PersonFrameworkAssignment} for collection actions
# (request / index) and an {EvidenceRequest} for member actions
# (respond / decline / cancel). Both expose `person_id` + `framework_id`, so
# the assessment-access checks resolve uniformly.
#
# - request: the assessee, their manager chain, an active rating delegate, or
#   a tenant admin may ask someone for evidence on the assessment.
# - respond / decline: only the requestee (the person being asked).
# - cancel: the original requester or a tenant admin.
class EvidenceRequestPolicy < ApplicationPolicy
  # GET hub list — any signed-in person sees their own incoming/outgoing
  # (the controller scopes the query to current_person).
  def index?
    person.present?
  end

  # POST — create a request against the assessment.
  def request?
    return false unless person.present?
    return true if tenant_admin?
    return true if record.person_id == person.id
    return true if active_rating_delegate?

    in_assessee_manager_chain?
  end

  # POST respond — only the requestee.
  def respond?
    requestee?
  end

  # POST decline — only the requestee.
  def decline?
    requestee?
  end

  # POST cancel — the requester or a tenant admin.
  def cancel?
    return false unless person.present?

    record.respond_to?(:requested_by_id) && (record.requested_by_id == person.id || tenant_admin?)
  end

  private

  def requestee?
    person.present? && record.respond_to?(:requestee_person_id) && record.requestee_person_id == person.id
  end

  def in_assessee_manager_chain?
    assessee = Person.find_by(id: record.person_id)
    assessee&.managed_by?(person) || false
  end

  def active_rating_delegate?
    return false unless record.respond_to?(:framework_id) && record.framework_id

    ManagerAssessmentDelegation.active_delegate?(
      person_id: record.person_id,
      framework_id: record.framework_id,
      delegate_person_id: person.id
    )
  end
end
