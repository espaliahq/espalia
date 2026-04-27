# frozen_string_literal: true

# Authorization policy for assessment resources.
#
# The record is a {PersonFrameworkAssignment}. Access is granted to
# the person themselves (for self-assessment) or their manager
# (for manager rating and alignment).
#
class AssessmentPolicy < ApplicationPolicy
  # @return [Boolean]
  def index? = person.present?

  # @return [Boolean]
  def show? = owns_assessment? || manages_assessee?

  # @return [Boolean]
  def matrix? = show?

  # @return [Boolean]
  def scoring? = show?

  # @return [Boolean]
  def create_self_rating? = owns_assessment?

  # @return [Boolean]
  def create_manager_rating? = manages_assessee?

  # Either the assessee or their manager can record an alignment.
  # Alignment is a shared act, not a manager-only one.
  #
  # @return [Boolean]
  def create_alignment_rating? = owns_assessment? || manages_assessee?

  # Whether the viewer may switch into alignment mode in the UI.
  #
  # @return [Boolean]
  def align? = create_alignment_rating?

  private

  # The current user's person matches the assignment's person.
  #
  # @return [Boolean]
  def owns_assessment?
    person.present? && record.person_id == person.id
  end

  # The current user's person is the manager of the assignment's person.
  #
  # @return [Boolean]
  def manages_assessee?
    return false unless person.present?

    assessee = Person.find_by(id: record.person_id)
    assessee&.manager_id == person.id
  end
end
