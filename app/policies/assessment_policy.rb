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
  def show? = owns_assessment? || manages_assessee? || active_rating_delegate?

  # @return [Boolean]
  def matrix? = show?

  # @return [Boolean]
  def scoring? = show?

  # @return [Boolean]
  def create_self_rating? = owns_assessment? && individual_ratings_editable?

  # A direct (recorded) manager OR an active delegate may record manager
  # ratings — delegation is for cases where the reporting manager lacks
  # visibility (e.g. the report is seconded into another team).
  #
  # @return [Boolean]
  def create_manager_rating?
    (manages_assessee? || active_rating_delegate?) && individual_ratings_editable?
  end

  # Grant/revoke a manager-rating delegation. Any ancestor manager (direct,
  # skip-level, …) or a tenant admin may delegate the reporting manager's
  # rating authority. Distinct from `manages_assessee?` (direct-recorded
  # manager only) which gates the rating itself.
  #
  # @return [Boolean]
  def delegate_manager_rating?
    tenant_admin? || assessee_managed_by_actor?
  end

  # @return [Boolean]
  def revoke_manager_rating_delegation? = delegate_manager_rating?

  # Remove a person's framework assignment entirely. A destructive
  # org-structure change — the same kind of authority HRIS-driven
  # (un)assignment carries — so it is gated to tenant admins, not the
  # assessee or their manager.
  #
  # @return [Boolean]
  def unassign? = tenant_admin?

  # Either the assessee or their manager can record an alignment, but only
  # while the cycle is in the `aligning` lifecycle state — i.e. the manager
  # has explicitly started alignment.
  #
  # @return [Boolean]
  def create_alignment_rating?
    (owns_assessment? || manages_assessee?) && alignment_in_progress?
  end

  # Whether the assessment should render in alignment mode for the viewer.
  # True once the manager has formally started alignment (cycle status
  # `aligning` or `aligned`). Both parties see all three rating perspectives
  # — self, manager, and aligned — with aligned values as the primary view.
  #
  # Before alignment starts, the assessee sees `:self` only and the manager
  # sees `:manager` only; the manager's ratings are private to the manager
  # until they choose to start alignment.
  #
  # @return [Boolean]
  def view_alignment?
    return false unless owns_assessment? || manages_assessee? || active_rating_delegate?

    %w[aligning aligned].include?(current_open_cycle_participation&.status)
  end

  # Only the assessee's current direct manager can formally start
  # alignment for a cycle. Requires the participant to have at least
  # begun rating (status `started`) — there must be something to align on.
  #
  # @return [Boolean]
  def start_alignment?
    return false unless manages_assessee?

    current_open_cycle_participation&.status == "started"
  end

  # Only the assessee's current direct manager can mark alignment
  # complete. Requires the cycle to be in the `aligning` state.
  #
  # @return [Boolean]
  def complete_alignment?
    return false unless manages_assessee?

    current_open_cycle_participation&.status == "aligning"
  end

  # Only the assessee's current direct manager can re-open a completed
  # alignment — to correct a completion made by accident. Allowed only
  # while the cycle is still open (the participation comes from the open
  # cycle) and currently `aligned`. Mirrors {#complete_alignment?}: it's
  # the inverse milestone, manager-owned, never a delegate.
  #
  # @return [Boolean]
  def reopen_alignment?
    return false unless manages_assessee?

    current_open_cycle_participation&.status == "aligned"
  end

  private

  # Whether self/manager ratings are still mutable for the current cycle.
  #
  # @return [Boolean]
  def individual_ratings_editable?
    participant = current_open_cycle_participation
    return true if participant.nil? # no participant row yet — pre-cycle edits permitted

    participant.individual_ratings_editable?
  end

  def alignment_in_progress?
    current_open_cycle_participation&.alignment_in_progress? || false
  end

  def current_open_cycle_present?
    current_open_cycle_participation.present?
  end

  def current_open_cycle_participation
    record.current_open_cycle_participation
  end

  # The current user's person matches the assignment's person.
  #
  # @return [Boolean]
  def owns_assessment?
    person.present? && record.person_id == person.id
  end

  # The current user's person is the assessee's reporting manager.
  #
  # Recorded-authoritative: reads the reporting manager captured on the
  # PersonDevelopment stream ({RecordedReportingManager}). Falls back to the
  # live `Person.manager_id` only when nothing has been recorded yet (manual /
  # non-HRIS tenant, or pre-backfill), so those tenants keep working.
  #
  # Alignment-related actions remain manager-only (a 1:1 conversation);
  # delegates are excluded from them. Skip-level access for evidence is granted
  # through {EvidencePolicy}, not this policy.
  #
  # @return [Boolean]
  def manages_assessee?
    return false unless person.present?

    recorded = RecordedReportingManager.manager_id_for(record.person_id, record.framework_id)
    return recorded == person.id if recorded.present?

    assessee = Person.find_by(id: record.person_id)
    assessee&.manager_id == person.id
  end

  # The current user's person holds an active manager-rating delegation for
  # this assessment.
  #
  # @return [Boolean]
  def active_rating_delegate?
    return false unless person.present?

    ManagerAssessmentDelegation.active_delegate?(
      person_id: record.person_id,
      framework_id: record.framework_id,
      delegate_person_id: person.id
    )
  end

  # Whether the actor is anywhere in the assessee's manager chain (direct,
  # skip-level, …) — used to gate who may grant/revoke a delegation.
  #
  # @return [Boolean]
  def assessee_managed_by_actor?
    return false unless person.present?

    assessee = Person.find_by(id: record.person_id)
    assessee&.managed_by?(person) || false
  end
end
