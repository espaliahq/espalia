# frozen_string_literal: true

# What per-role alignment has done to a participation's cells (ADR-22).
#
# **Disclosure.** A manager's rating on a cell is disclosed to the assessee
# once alignment has started against a role whose scope contains the cell —
# the union of every started role's scope. Starting E3 alignment discloses
# E3's cells; a cell only PM3 reads stays private until the manager starts
# alignment against PM3. Consulted only for the assessee: the manager side
# sees every cell.
#
# **Freeze.** Self and manager ratings freeze on the same union: a cell is
# frozen once any started role reads it, whichever lens the page is read
# through, and {#frozen_by} names the role so the pill can say why. A home
# alignment started before per-role alignment froze the whole assessment and
# still does ({Alignment#whole}), matching the aggregate.
#
# The home role's lifecycle is the participation's `status`
# ({AssessmentCycleProgress}); every other role's is its
# {AssessmentCycleRoleAlignment} row. The set does not depend on the lens.
#
# @example
#   disclosure = Assessments::Disclosure.for(lens: lens, participant_status: "aligning")
#   disclosure.include?(stable_id, 3)        # manager rating visible to the assessee?
#   disclosure.frozen_by(stable_id, 3)&.code # => "PM3"
class Assessments::Disclosure
  STARTED_STATUSES = %w[aligning aligned].freeze

  # One alignment started in the participation's cycle.
  #
  # `code` is the role and the level the conversation is about ("PM3");
  # `whole` marks a start from before per-role alignment, which freezes
  # every cell; `scope` is the cells it discloses.
  Alignment = Data.define(:role_id, :code, :label, :level_ordinal, :status, :home, :whole, :scope) do
    # @return [Boolean]
    def aligned? = status == "aligned"

    # @return [Boolean] whether this alignment freezes the cell
    def covers?(capability_stable_id, level_ordinal)
      whole || scope.include?(capability_stable_id, level_ordinal)
    end
  end

  # @param lens [Assessments::Lens] any lens on the assignment — only its
  #   home is read
  # @param participant_status [String, nil] the home participation's status
  # @return [Assessments::Disclosure]
  def self.for(lens:, participant_status:)
    assignment = lens.assignment
    cycle_id = assignment.current_open_cycle&.cycle_id
    rows = cycle_id ? AssessmentCycleRoleAlignment.for_participation(cycle_id: cycle_id, person_id: assignment.person_id).to_a : []
    home_rows, lens_rows = rows.partition { |row| row.role_id == lens.home_role.role_id }

    alignments = []
    alignments << home_alignment(lens, participant_status, home_rows.first) if STARTED_STATUSES.include?(participant_status)
    alignments.concat(lens_alignments(lens_rows, framework_id: assignment.framework_id))
    new(alignments.flat_map { |alignment| alignment.scope.cells.to_a }, alignments: alignments)
  end

  # @return [Assessments::Disclosure] discloses and freezes nothing
  def self.none
    new(Set.new)
  end

  def self.home_alignment(lens, status, row)
    Alignment.new(
      role_id: lens.home_role.role_id, code: lens.home_code, label: "#{lens.home_role.name} · #{lens.home_code}",
      level_ordinal: lens.home_level.ordinal, status: status, home: true,
      whole: row&.whole_assessment || false, scope: lens.home_scope
    )
  end
  private_class_method :home_alignment

  def self.lens_alignments(rows, framework_id:)
    return [] if rows.empty?

    role_ids = rows.map(&:role_id)
    scopes = Assessments::RoleScope.for_roles(role_ids: role_ids, framework_id: framework_id)
    roles = FrameworkState::Role.where(role_id: role_ids).index_by(&:role_id)
    rows.filter_map do |row|
      role = roles[row.role_id]
      next unless role

      code = "#{role.code}#{row.level_ordinal}"
      Alignment.new(role_id: row.role_id, code: code, label: "#{role.name} · #{code}",
                    level_ordinal: row.level_ordinal, status: row.status, home: false,
                    whole: row.whole_assessment, scope: scopes.fetch(row.role_id))
    end
  end
  private_class_method :lens_alignments

  # @return [Array<Alignment>] every alignment started in the cycle
  attr_reader :alignments

  # @param cells [Enumerable<Array(String, Integer)>] the disclosed cells
  # @param alignments [Array<Alignment>] the started alignments behind them
  def initialize(cells, alignments: [])
    @cells = cells.to_set
    @alignments = alignments
  end

  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @return [Boolean] the assessee may see the manager's rating here
  def include?(capability_stable_id, level_ordinal)
    @cells.include?([ capability_stable_id, level_ordinal ])
  end

  # @param cells [Enumerable<Array(String, Integer)>]
  # @return [Boolean] every one of the cells is disclosed
  def covers_all?(cells)
    cells.all? { |stable_id, ordinal| include?(stable_id, ordinal) }
  end

  # @return [Boolean] self and manager ratings on the cell are frozen
  def frozen?(capability_stable_id, level_ordinal)
    !frozen_by(capability_stable_id, level_ordinal).nil?
  end

  # The alignment that froze a cell, the home one first when several did.
  #
  # @return [Alignment, nil]
  def frozen_by(capability_stable_id, level_ordinal)
    covering(capability_stable_id, level_ordinal).min_by { |alignment| alignment.home ? 0 : 1 }
  end

  # Whether the agreed value on a cell can't be recorded or cleared: no
  # alignment reading it is in progress, or a completed one already agreed
  # it — the rule the aggregate enforces. False when no alignment is known
  # at all, leaving the page's own lifecycle to decide.
  #
  # @param agreed [Boolean] the cell already carries an agreed value
  # @return [Boolean]
  def agreed_value_locked?(capability_stable_id, level_ordinal, agreed:)
    return false if @alignments.empty?

    completed, in_progress = covering(capability_stable_id, level_ordinal).partition(&:aligned?)
    in_progress.empty? || (agreed && completed.any?)
  end

  # @param role_id [String]
  # @return [Alignment, nil] the alignment started against that role
  def alignment_for(role_id)
    @alignments.find { |alignment| alignment.role_id == role_id }
  end

  # @return [Array<Alignment>] started alignments against roles other than home
  def lens_alignments
    @alignments.reject(&:home)
  end

  private

  def covering(capability_stable_id, level_ordinal)
    @alignments.select { |alignment| alignment.covers?(capability_stable_id, level_ordinal) }
  end
end
