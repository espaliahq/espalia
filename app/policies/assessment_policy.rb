# frozen_string_literal: true

# Authorization policy for assessment resources.
#
# The record is a {PersonFrameworkAssignment}. Viewing is granted to the
# person themselves, anyone in their manager chain (direct, skip-level, …),
# an active rating delegate, and tenant/global admins (HR view, read-only —
# they already see manager-perspective activity and evidence via
# {AssessmentVisibility#viewer_sees_all_evidence?}, and unsuppressed
# whole-cycle attainment aggregates). Rating and alignment authority stay
# much narrower — the recorded reporting manager (plus a delegate for the
# manager rating only).
#
class AssessmentPolicy < ApplicationPolicy
  # @return [Boolean]
  def index? = person.present?

  # @return [Boolean]
  def show?
    tenant_admin? || owns_assessment? || manages_assessee? ||
      in_assessee_manager_chain? || active_rating_delegate?
  end

  # Whether the viewer is an active rating-side participant — the assessee,
  # the recorded reporting manager, or an active rating delegate — as opposed
  # to a view-only manager-chain ancestor. Phase-independent (ignores cycle
  # freezing): drives UI copy such as the hero's "Rate …" prompts, not access
  # control.
  #
  # @return [Boolean]
  def rating_participant?
    owns_assessment? || manages_assessee? || active_rating_delegate?
  end

  # @return [Boolean]
  def matrix? = show?

  # @return [Boolean]
  def scoring? = show?

  # Freeze is per cell (ADR-22): a started alignment freezes only the cells
  # its role reads, so this asks only whether the participation still takes
  # ratings. The rating Operations refuse a frozen cell
  # ({Operations::Assessments::RatingCell}), and the aggregate backs them.
  #
  # @return [Boolean]
  def create_self_rating? = owns_assessment? && individual_ratings_editable?

  # A direct (recorded) manager OR an active delegate may record manager
  # ratings — delegation is for cases where the reporting manager lacks
  # visibility (e.g. the report is seconded into another team). On any cell
  # a lens reads (ADR-22): the rating stays private to the manager side
  # until alignment starts against a role that reads the cell.
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
    tenant_admin? || in_assessee_manager_chain?
  end

  # @return [Boolean]
  def revoke_manager_rating_delegation? = delegate_manager_rating?

  # Declare an exploration of another role or level (ADR-22) — "we've
  # agreed to explore PM3". The assessee, their recorded reporting manager
  # or an active rating delegate: the people the conversation is between. A
  # view-only ancestor or an admin outside the chain can read the
  # exploration but not declare one. Needs no open cycle — it writes no
  # rating.
  #
  # @return [Boolean]
  def start_exploration? = rating_participant?

  # Close a declared exploration with its outcome — the same people who
  # may declare one, whoever declared it.
  #
  # @return [Boolean]
  def close_exploration? = rating_participant?

  # Remove a person's framework assignment entirely. A destructive
  # org-structure change — the same kind of authority HRIS-driven
  # (un)assignment carries — so it is gated to tenant admins, not the
  # assessee or their manager.
  #
  # @return [Boolean]
  def unassign? = tenant_admin?

  # Either the assessee or their manager can record an alignment, but only
  # while an alignment is in progress — against the home role (status
  # `aligning`) or another role. Which cells it may touch is the
  # Operation's per-cell check.
  #
  # @return [Boolean]
  def create_alignment_rating?
    (owns_assessment? || manages_assessee?) &&
      (alignment_in_progress? || open_role_alignments.any? { |row| row.status == "aligning" })
  end

  # Whether the assessment, read against a role, should render in alignment
  # mode for the viewer. True once the manager has formally started
  # alignment against that role (ADR-22): for the home role, the cycle
  # status is `aligning` or `aligned`; for another role, its
  # {AssessmentCycleRoleAlignment} row exists. Both parties then see all
  # three rating perspectives — self, manager, and aligned — with aligned
  # values as the primary view.
  #
  # Before alignment starts, the assessee sees `:self` only and the manager
  # sees `:manager` only; the manager's ratings are private to the manager
  # until they choose to start alignment.
  #
  # @param role_id [String, nil] the role read against; nil = the home role
  # @return [Boolean]
  def view_alignment?(role_id: nil)
    return false unless show?
    return %w[aligning aligned].include?(current_open_cycle_participation&.status) if role_id.nil?

    !role_alignment(role_id).nil?
  end

  # Only the assessee's recorded reporting manager can formally start
  # alignment — never a delegate, never an admin outside the chain (ADR-22).
  # Against the home role it needs the participant to have begun rating
  # (status `started`): there must be something to align on. Against
  # another role, any live participation, as long as alignment hasn't
  # already started against that role.
  #
  # @param role_id [String, nil] the role to align against; nil = home
  # @return [Boolean]
  def start_alignment?(role_id: nil)
    return false unless manages_assessee?
    return current_open_cycle_participation&.status == "started" if home_role?(role_id)

    live_participation? && role_alignment(role_id).nil?
  end

  # Only the assessee's recorded reporting manager can mark alignment
  # against a role complete, while it is in progress.
  #
  # @param role_id [String, nil] nil = home
  # @return [Boolean]
  def complete_alignment?(role_id: nil)
    return false unless manages_assessee?
    return current_open_cycle_participation&.status == "aligning" if home_role?(role_id)

    role_alignment(role_id)&.status == "aligning"
  end

  # Only the assessee's recorded reporting manager can re-open a completed
  # alignment — to correct a completion made by accident. Allowed only
  # while the cycle is still open (the participation comes from the open
  # cycle) and the role's alignment is currently `aligned`. Mirrors
  # {#complete_alignment?}: the inverse milestone, manager-owned, never a
  # delegate.
  #
  # @param role_id [String, nil] nil = home
  # @return [Boolean]
  def reopen_alignment?(role_id: nil)
    return false unless manages_assessee?
    return current_open_cycle_participation&.status == "aligned" if home_role?(role_id)

    role_alignment(role_id)&.status == "aligned"
  end

  private

  # Whether the participation still takes self/manager ratings on some
  # cell. A started alignment freezes only its role's cells (ADR-22), so
  # an aligning participation still takes ratings on cells no started role
  # reads; the cell itself is checked by the rating Operations.
  #
  # @return [Boolean]
  def individual_ratings_editable?
    return true if current_open_cycle_participation.nil? # no participant row yet — pre-cycle edits permitted

    live_participation?
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

  # @return [AssessmentCycleRoleAlignment, nil] alignment started against
  #   the role in the open cycle
  def role_alignment(role_id)
    open_role_alignments.find { |row| row.role_id == role_id }
  end

  # @return [Array<AssessmentCycleRoleAlignment>]
  def open_role_alignments
    @open_role_alignments ||= begin
      cycle = record.current_open_cycle
      cycle ? AssessmentCycleRoleAlignment.for_participation(cycle_id: cycle.cycle_id, person_id: record.person_id).to_a : []
    end
  end

  # Whether a role is the one the open cycle assesses the person at.
  def home_role?(role_id)
    role_id.nil? || role_id == home_role_id
  end

  def home_role_id
    return @home_role_id if defined?(@home_role_id)

    cycle = record.current_open_cycle
    home = cycle && Assessments::RoleScope.home_role_ids(cycle_id: cycle.cycle_id, framework_id: record.framework_id,
                                                         person_ids: [ record.person_id ])[record.person_id]
    @home_role_id = home || record.role_id
  end

  # An open-cycle participation still taking part.
  def live_participation?
    %w[enrolled started aligning aligned].include?(current_open_cycle_participation&.status)
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
  # delegates and manager-chain ancestors are excluded from them.
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
  # skip-level, …). Grants full view access ({#show?}) and gates who may
  # grant/revoke a delegation — but never rating or alignment authority,
  # which stay with the recorded reporting manager ({#manages_assessee?}).
  #
  # Walks the live org chart (`Person#managed_by?`), unlike the
  # recorded-authoritative direct-manager check.
  #
  # @return [Boolean]
  def in_assessee_manager_chain?
    return false unless person.present?

    assessee = Person.find_by(id: record.person_id)
    assessee&.managed_by?(person) || false
  end
end
