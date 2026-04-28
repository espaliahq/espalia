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
  def create_self_rating? = owns_assessment? && individual_ratings_editable?

  # @return [Boolean]
  def create_manager_rating? = manages_assessee? && individual_ratings_editable?

  # Either the assessee or their manager can record an alignment, but only
  # while the cycle is in the `aligning` lifecycle state — i.e. the manager
  # has explicitly started alignment.
  #
  # @return [Boolean]
  def create_alignment_rating?
    (owns_assessment? || manages_assessee?) && alignment_in_progress?
  end

  # Whether the viewer may switch into alignment mode in the UI.
  # Visible whenever either party can take part in alignment, OR the
  # current viewer is the manager and could start alignment.
  #
  # @return [Boolean]
  def align? = (owns_assessment? || manages_assessee?) && current_open_cycle_present?

  # Only the assessee's current direct manager can formally start
  # alignment for a cycle. Requires the participant to have at least
  # begun rating (status `started`) — there must be something to align on.
  #
  # @return [Boolean]
  def start_alignment?
    return false unless manages_assessee?

    current_open_cycle_participant&.status == "started"
  end

  private

  # Whether self/manager ratings are still mutable for the current cycle.
  #
  # @return [Boolean]
  def individual_ratings_editable?
    participant = current_open_cycle_participant
    return true if participant.nil? # no participant row yet — pre-cycle edits permitted

    participant.individual_ratings_editable?
  end

  def alignment_in_progress?
    current_open_cycle_participant&.alignment_in_progress? || false
  end

  def current_open_cycle_present?
    current_open_cycle_participant.present?
  end

  def current_open_cycle_participant
    record.current_open_cycle_participant
  end

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
