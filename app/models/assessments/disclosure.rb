# frozen_string_literal: true

# The cells whose manager and aligned ratings the assessee may see (ADR-22).
#
# A manager's rating on a cell is disclosed once alignment has started
# against a role whose scope contains the cell. Until per-role alignment
# exists, the only such role is the home role, so the set is the home scope
# once home alignment is `aligning` or `aligned`, and empty before. Read
# through any lens, a shared cell the home conversation disclosed stays
# disclosed and a cell only the lens role reads stays private.
#
# Consulted only for the assessee: the manager side sees every cell.
#
# @example
#   disclosure = Assessments::Disclosure.for(lens: lens, participant_status: "aligned")
#   disclosure.include?(stable_id, 3)
class Assessments::Disclosure
  STARTED_STATUSES = %w[aligning aligned].freeze

  # @param lens [Assessments::Lens]
  # @param participant_status [String, nil] the home participation's status
  # @return [Assessments::Disclosure]
  def self.for(lens:, participant_status:)
    return none unless STARTED_STATUSES.include?(participant_status)

    new(lens.home_scope.cells)
  end

  # @return [Assessments::Disclosure] discloses nothing
  def self.none
    new(Set.new)
  end

  # @param cells [Enumerable<Array(String, Integer)>]
  def initialize(cells)
    @cells = cells.to_set
  end

  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @return [Boolean]
  def include?(capability_stable_id, level_ordinal)
    @cells.include?([ capability_stable_id, level_ordinal ])
  end
end
