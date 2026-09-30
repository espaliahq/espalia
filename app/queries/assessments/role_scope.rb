# frozen_string_literal: true

# The cells one role reads: every `(capability_stable_id, level_ordinal)` where
# an active capability bound to the role carries a behavioural expectation.
#
# A rating is a fact about the person at a cell, not about a role (ADR-22), so
# every reader has to say which role it reads for. This is the one definition
# of that set; readers filter ratings through
# `AssessmentLevelRating.within(scope)`, and scoring takes {#bindings} from
# here, so the hero, coverage, reports and calibration can never disagree on
# which cells count.
#
# Built fresh on every call rather than cached per request: the projection
# runs readers on every rating event, and during a replay the framework's
# shape changes between one event and the next.
#
# @example
#   scope = Assessments::RoleScope.for(role_id: role.role_id, framework_id: framework_id)
#   AssessmentLevelRating.for_cycle(cycle_id).for_person(person_id).within(scope)
class Assessments::RoleScope
  attr_reader :role_id, :framework_id, :bindings, :cells

  # @param role_id [String]
  # @param framework_id [String]
  # @return [Assessments::RoleScope]
  def self.for(role_id:, framework_id:)
    for_roles(role_ids: [ role_id ], framework_id: framework_id).fetch(role_id)
  end

  # Loads several roles' scopes in two queries — the path for cohort readers,
  # which need one scope per role in the population.
  #
  # @param role_ids [Array<String>]
  # @param framework_id [String]
  # @return [Hash{String => Assessments::RoleScope}] one entry per requested
  #   role, empty for a role with no active bound capabilities
  def self.for_roles(role_ids:, framework_id:)
    role_ids = role_ids.compact.uniq
    return {} if role_ids.empty?

    bindings = FrameworkState::CapabilityRoleBinding
      .joins(capability: :category)
      .where(role_id: role_ids)
      .merge(FrameworkState::Capability.active)
      .where(framework_capability_categories: { framework_id: framework_id })
      .includes(:capability)
      .to_a
    cells = FrameworkState::BehaviouralExpectation.stable_cells(bindings.map(&:capability_id).uniq)
    cells_by_stable_id = cells.group_by(&:first)
    bindings_by_role = bindings.group_by(&:role_id)

    role_ids.index_with do |role_id|
      role_bindings = bindings_by_role.fetch(role_id, [])
      role_cells = role_bindings.flat_map { |b| cells_by_stable_id.fetch(b.capability.stable_id, []) }
      new(role_id: role_id, framework_id: framework_id, bindings: role_bindings, cells: role_cells)
    end
  end

  # Each person's home-role scope for a cycle: the role their enrollment
  # snapshot assesses them at (ADR-19), falling back to the live assignment
  # only for an enrollment that predates the snapshot column. A person with
  # neither gets an empty scope, so none of their ratings count.
  #
  # @param cycle_id [String]
  # @param framework_id [String]
  # @param person_ids [Array<String>]
  # @return [Hash{String => Assessments::RoleScope}]
  def self.for_people(cycle_id:, framework_id:, person_ids:)
    person_ids = person_ids.uniq
    return {} if person_ids.empty?

    role_by_person = AssessmentCycleEnrollment
      .where(cycle_id: cycle_id, person_id: person_ids)
      .where.not(role_id: nil)
      .pluck(:person_id, :role_id).to_h
    missing = person_ids - role_by_person.keys
    if missing.any?
      role_by_person.merge!(
        PersonFrameworkAssignment.where(framework_id: framework_id, person_id: missing)
          .pluck(:person_id, :role_id).to_h
      )
    end

    scopes = for_roles(role_ids: role_by_person.values, framework_id: framework_id)
    person_ids.index_with do |person_id|
      scopes[role_by_person[person_id]] || empty(framework_id: framework_id)
    end
  end

  # A scope that reads nothing — for a person whose role is unknown.
  #
  # @param framework_id [String]
  # @return [Assessments::RoleScope]
  def self.empty(framework_id:)
    new(role_id: nil, framework_id: framework_id, bindings: [], cells: [])
  end

  # @param role_id [String, nil]
  # @param framework_id [String]
  # @param bindings [Array<FrameworkState::CapabilityRoleBinding>] active
  #   bindings, capability preloaded
  # @param cells [Enumerable<Array(String, Integer)>]
  def initialize(role_id:, framework_id:, bindings:, cells:)
    @role_id = role_id
    @framework_id = framework_id
    @bindings = bindings.freeze
    @cells = cells.to_set.freeze
  end

  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @return [Boolean]
  def include?(capability_stable_id, level_ordinal)
    @cells.include?([ capability_stable_id, level_ordinal ])
  end

  # The same role narrowed to one level — the cells a coverage or completion
  # count is taken over.
  #
  # @param level_ordinal [Integer]
  # @return [Assessments::RoleScope]
  def at_level(level_ordinal)
    level_cells = @cells.select { |_, ordinal| ordinal == level_ordinal }
    stable_ids = level_cells.to_set(&:first)
    self.class.new(
      role_id: @role_id, framework_id: @framework_id,
      bindings: @bindings.select { |b| stable_ids.include?(b.capability.stable_id) },
      cells: level_cells
    )
  end

  # @return [Set<String>] the capabilities with at least one cell in scope
  def capability_stable_ids
    @capability_stable_ids ||= @cells.to_set(&:first)
  end

  # @return [Boolean]
  def empty?
    @cells.empty?
  end

  # Value equality, so readers can group people by scope.
  #
  # @return [Boolean]
  def eql?(other)
    other.is_a?(self.class) && other.role_id == @role_id && other.cells == @cells
  end
  alias == eql?

  # @return [Integer]
  def hash
    @hash ||= [ self.class, @role_id, @cells ].hash
  end
end
