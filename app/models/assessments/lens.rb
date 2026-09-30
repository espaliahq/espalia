# frozen_string_literal: true

# The role and level an assessment is read against (ADR-22).
#
# Every assessment has a home: the role and level the open cycle's
# enrollment snapshot assesses the person at (ADR-19), or the live
# assignment when there is no snapshot. That is the record. A lens reads
# the same ratings through another role's bindings and another level — "how
# would I read as a PM3?" — and writes nothing of its own: ratings are facts
# about a cell, and the lens only chooses which cells count.
#
# Resolved once per request from `as_role` / `as_level`, then threaded
# wherever a role goes, so the page, its frames, the rating responses and
# the MCP payloads all read the same pair.
#
# @example
#   lens = Assessments::Lens.resolve(assignment: assignment, as_role: pm.role_id, as_level: 3)
#   lens.home?            # => false
#   lens.code             # => "PM3"
#   lens.home_code        # => "E3"
class Assessments::Lens
  # A role or level outside the assignment's framework. A RecordNotFound, so
  # a controller answers 404 without its own rescue.
  class NotFound < ActiveRecord::RecordNotFound; end

  attr_reader :assignment, :role, :level, :home_role, :home_level

  # The assignment read as itself.
  #
  # @param assignment [PersonFrameworkAssignment]
  # @return [Assessments::Lens]
  # @raise [ActiveRecord::RecordNotFound] when the home role or level is gone
  def self.home(assignment)
    resolve(assignment: assignment)
  end

  # @param assignment [PersonFrameworkAssignment]
  # @param as_role [String, nil] a role_id in the assignment's framework;
  #   blank keeps the home role
  # @param as_level [Integer, String, nil] a level ordinal in that role; blank
  #   picks the role's level nearest the home ordinal
  # @return [Assessments::Lens]
  # @raise [NotFound] for a role or level the framework doesn't have
  # @raise [ActiveRecord::RecordNotFound] when the home role or level is gone
  def self.resolve(assignment:, as_role: nil, as_level: nil)
    home_role, home_level = home_pair(assignment)
    role = as_role.present? ? framework_role(assignment, as_role) : home_role
    level =
      if as_level.present?
        ordinal = Integer(as_level.to_s, exception: false)
        role.levels.find { |lvl| lvl.ordinal == ordinal }
      elsif role == home_role
        home_level
      else
        nearest_level(role, home_level.ordinal)
      end
    raise NotFound, "No level #{as_level.inspect} in role #{role.code}" unless level

    new(assignment: assignment, role: role, level: level, home_role: home_role, home_level: home_level)
  end

  # The URL / Operation params that name a lens, relative to a home: empty
  # for the home itself, `as_level` alone on the home role's ladder.
  #
  # @return [Hash{Symbol => String, Integer}]
  def self.params_for(home_role_id:, home_ordinal:, role_id:, ordinal:)
    return {} if role_id == home_role_id && ordinal == home_ordinal
    return { as_level: ordinal } if role_id == home_role_id

    { as_role: role_id, as_level: ordinal }
  end

  # @return [Array(FrameworkState::Role, FrameworkState::Level)]
  def self.home_pair(assignment)
    snapshot = open_cycle_snapshot(assignment)
    role_id, level_id =
      if snapshot&.role_id && snapshot.level_id
        [ snapshot.role_id, snapshot.level_id ]
      else
        [ assignment.role_id, assignment.level_id ]
      end
    role = FrameworkState::Role.includes(:levels).find_by!(role_id: role_id)
    level = role.levels.find { |lvl| lvl.level_id == level_id } ||
      raise(ActiveRecord::RecordNotFound, "Home level #{level_id} is not in role #{role.code}")
    [ role, level ]
  end
  private_class_method :home_pair

  def self.open_cycle_snapshot(assignment)
    cycle = assignment.current_open_cycle
    cycle && AssessmentCycleEnrollment.find_by(cycle_id: cycle.cycle_id, person_id: assignment.person_id)
  end
  private_class_method :open_cycle_snapshot

  def self.framework_role(assignment, role_id)
    FrameworkState::Role
      .joins(:role_family)
      .where(framework_role_families: { framework_id: assignment.framework_id })
      .includes(:levels)
      .find_by(role_id: role_id) || raise(NotFound, "No role #{role_id} in this framework")
  end
  private_class_method :framework_role

  # Ties go to the lower level, so an explorer link never lands above the
  # person's own ordinal when the target role skips it.
  def self.nearest_level(role, ordinal)
    role.levels.min_by { |lvl| [ (lvl.ordinal - ordinal).abs, lvl.ordinal ] } ||
      raise(NotFound, "Role #{role.code} has no levels")
  end
  private_class_method :nearest_level

  def initialize(assignment:, role:, level:, home_role:, home_level:)
    @assignment = assignment
    @role = role
    @level = level
    @home_role = home_role
    @home_level = home_level
  end

  # @return [Boolean] reading the record itself
  def home?
    home_role? && @level.ordinal == @home_level.ordinal
  end

  # @return [Boolean] reading the home role, at any level
  def home_role?
    @role.role_id == @home_role.role_id
  end

  # @return [Assessments::RoleScope] the cells the lens role reads
  def scope
    @scope ||= Assessments::RoleScope.for(role_id: @role.role_id, framework_id: framework_id)
  end

  # @return [Assessments::RoleScope] the cells the record reads
  def home_scope
    return scope if home_role?

    @home_scope ||= Assessments::RoleScope.for(role_id: @home_role.role_id, framework_id: framework_id)
  end

  # Unrated cells count as consistent below this ordinal (ADR-22): below
  # both the level read and the home level.
  #
  # @return [Integer]
  def assumed_below
    [ @level.ordinal, @home_level.ordinal ].min
  end

  # @return [Hash] the params naming this lens; empty for the home
  def to_params
    params_for(role_id: @role.role_id, ordinal: @level.ordinal)
  end

  # @return [Hash] the params naming another lens from this one's home
  def params_for(role_id:, ordinal:)
    self.class.params_for(home_role_id: @home_role.role_id, home_ordinal: @home_level.ordinal,
                          role_id: role_id, ordinal: ordinal)
  end

  # Every role in the framework with its levels, grouped by role family —
  # what the header's "Another role…" picker offers. Families and roles in
  # name order; levels by ordinal.
  #
  # @return [Array<Array(String, Array<FrameworkState::Role>)>]
  def ladders
    @ladders ||= FrameworkState::Role
      .joins(:role_family)
      .where(framework_role_families: { framework_id: framework_id })
      .includes(:role_family, :levels)
      .reject { |role| role.levels.empty? }
      .group_by { |role| role.role_family.name }
      .sort_by(&:first)
      .map { |family, roles| [ family, roles.sort_by(&:name) ] }
  end

  # @return [String] e.g. "PM3" — the shortcode the header chip shows
  def code = "#{@role.code}#{@level.ordinal}"

  # @return [String] e.g. "E3"
  def home_code = "#{@home_role.code}#{@home_level.ordinal}"

  # @return [String] e.g. "Product Manager · PM3"
  def label = "#{@role.name} · #{code}"

  # @return [String]
  def framework_id = @assignment.framework_id

  # What an MCP client needs to tell a lens number from the record.
  #
  # @return [Hash]
  def payload
    { role_id: @role.role_id, role_code: @role.code, level_ordinal: @level.ordinal, home: home? }
  end
end
