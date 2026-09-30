# frozen_string_literal: true

# View-model wrapping a single HRIS-imported person with the data needed
# to render its row on the HRIS integration detail page.
#
# Mirrors the resolution logic in {Hris::Hibob::Adapter#dispatch_framework_assignment}
# so the displayed status reflects exactly what a sync would do today.
#
# Pure value object — no DB access. The controller is responsible for
# pre-loading the person, the matched mapping, the resolved role/level,
# and the existing assignment to avoid N+1 queries.
#
# @example
#   row = Integrations::HrisPersonRow.new(
#     person: person,
#     mapping: mapping,
#     role: role,
#     level: level,
#     assignment: assignment
#   )
#   row.status_label  # => "Assigned"
#   row.status_variant # => :success
#
class Integrations::HrisPersonRow
  STATUS_NO_TITLE         = :no_title
  STATUS_INACTIVE         = :inactive
  STATUS_UNMAPPED         = :unmapped
  STATUS_MISSING_ROLE     = :missing_role
  STATUS_MISSING_ORDINAL  = :missing_ordinal
  STATUS_MISSING_LEVEL    = :missing_level
  STATUS_ASSIGNED         = :assigned
  STATUS_PENDING_SYNC     = :pending_sync
  STATUS_DRIFT            = :drift

  attr_reader :person, :mapping, :role, :level, :assignment

  # @param person [Person]
  # @param mapping [HrisRoleMapping, nil] the resolved mapping for this person's title
  # @param role [FrameworkState::Role, nil] the framework role matched by mapping.framework_role_code
  # @param level [FrameworkState::Level, nil] the framework level matched by the resolved ordinal
  # @param assignment [PersonFrameworkAssignment, nil] existing assignment for this person, if any
  def initialize(person:, mapping: nil, role: nil, level: nil, assignment: nil)
    @person = person
    @mapping = mapping
    @role = role
    @level = level
    @assignment = assignment
  end

  # @return [Symbol] one of the STATUS_* constants
  def status
    return STATUS_INACTIVE if person.status == "inactive"
    return STATUS_NO_TITLE if person.job_title.blank?
    return STATUS_UNMAPPED if mapping.nil?
    return STATUS_MISSING_ROLE if role.nil?
    return STATUS_MISSING_ORDINAL if resolved_ordinal.nil?
    return STATUS_MISSING_LEVEL if level.nil?
    return STATUS_PENDING_SYNC if assignment.nil?
    return STATUS_DRIFT if assignment.role_id != role.role_id || assignment.level_id != level.level_id

    STATUS_ASSIGNED
  end

  # @return [String] the human-readable label for the row status
  def status_label
    case status
    when STATUS_INACTIVE        then "Inactive"
    when STATUS_NO_TITLE        then "No job title"
    when STATUS_UNMAPPED        then "Unmapped title"
    when STATUS_MISSING_ROLE    then "Missing role"
    when STATUS_MISSING_ORDINAL then "Missing level ordinal"
    when STATUS_MISSING_LEVEL   then "Missing level"
    when STATUS_PENDING_SYNC    then "Pending sync"
    when STATUS_DRIFT           then "Drifted"
    else                             "Assigned"
    end
  end

  # @return [Symbol] {Components::Kit::Badge} variant for the row status
  def status_variant
    case status
    when STATUS_ASSIGNED                       then :success
    when STATUS_PENDING_SYNC                   then :info
    when STATUS_INACTIVE, STATUS_NO_TITLE      then :default
    else                                            :warning
    end
  end

  # @return [String] the framework role code resolved by the mapping, or "—" if none
  def mapped_role_code
    mapping&.framework_role_code || "\u2014"
  end

  # @return [Integer, nil] the level ordinal that the adapter would use for this person
  def resolved_ordinal
    return nil if mapping.nil?

    mapping.level_ordinal || person.hris_level_ordinal
  end

  # @return [String] the current framework assignment label, or "—" if none
  def assigned_label
    return "\u2014" if assignment.nil? || assignment.role.nil? || assignment.level.nil?

    "#{assignment.role.code} L#{assignment.level.ordinal}"
  end

  # @return [String, nil] the assignment the next sync would give, in {#assigned_label}'s format
  def target_label
    return nil if role.nil? || level.nil?

    "#{role.code} L#{level.ordinal}"
  end

  # Whether the next sync would assign or reassign this person.
  #
  # @return [Boolean]
  def changes_on_sync?
    [ STATUS_PENDING_SYNC, STATUS_DRIFT ].include?(status)
  end

  # Whether this person keeps an assignment the sync can no longer resolve —
  # their title (or its role, or level) stopped matching, and the sync leaves
  # whatever an earlier title gave them.
  #
  # @return [Boolean]
  def stale_assignment?
    assignment.present? &&
      [ STATUS_UNMAPPED, STATUS_MISSING_ROLE, STATUS_MISSING_ORDINAL, STATUS_MISSING_LEVEL ].include?(status)
  end
end
