# frozen_string_literal: true

# What the viewer may change in one unit's drawer (#124), resolved from
# {OrgGraphPolicy} so the view only reads flags. The commands check again.
#
# A unit an HRIS supplies keeps its name and parent there. Its owners, and
# the members someone added by hand, stay editable here (#115).
class OrgGraphPolicy::UnitRights
  # @param policy [OrgGraphPolicy]
  # @param unit [OrgUnit]
  # @param overview [OrgGraph::UnitsOverview] the live units, for destinations
  def initialize(policy, unit, overview)
    @policy = policy
    @unit = unit
    @overview = overview
  end

  # @return [Boolean]
  def rename? = @unit.held_by_espalia? && @policy.edit_unit?(@unit)

  # @return [Boolean]
  def move? = rename? && (parent_choices.any? || root_choice? || conversion_parent_choices.any? || root_conversion_choice?)

  # Give the unit a structure of its own, or withdraw it ([#494](https://github.com/espaliahq/espalia/issues/494)).
  #
  # @return [Boolean]
  def structure? = @policy.edit_structure_of?(@unit)

  # @return [Boolean]
  def change_type?
    structure_unit_id = @overview.structure_unit_of(@unit)
    @unit.held_by_espalia? && @policy.change_unit_kind?(structure_unit_id && @overview.unit(structure_unit_id)) && type_choices.size > 1
  end

  # The types the unit may take today, from the structure in force where it
  # sits: its own, and each type Espalia supplies that may sit there and that
  # every live sub-unit may sit under. A unit that declares a structure seats
  # its sub-units at that structure's top, so they constrain nothing. The
  # command also checks the days from the chosen date.
  #
  # @return [Array<OrgGraph::Taxonomy::Kind>] top first
  def type_choices
    @type_choices ||= begin
      taxonomy = @overview.taxonomy(@unit)
      parent_kind = @overview.seated_parent_kind(@unit.parent)
      child_kinds = @overview.declares_structure?(@unit) ? [] : @overview.children_of(@unit).map(&:level_id).uniq
      taxonomy.kinds.select do |kind|
        next true if kind.id == @unit.level_id

        kind.provider == OrgGraph::Taxonomy::ESPALIA &&
          (parent_kind ? taxonomy.allows?(kind.id, beneath: parent_kind) : kind.top?) &&
          child_kinds.all? { taxonomy.allows?(it, beneath: kind.id) }
      end
    end
  end

  # @return [Boolean]
  def owners? = @policy.edit_unit?(@unit)

  # @return [Boolean]
  def add_members? = @policy.edit_unit?(@unit)

  # Where the unit may move: any live unit of a kind its own kind may sit
  # under, outside its own subtree and within the structure in force where
  # it sits, that the viewer may put a unit under. Moving into another
  # structure converts the unit, which this drawer doesn't offer.
  #
  # @return [Array<OrgUnit>] in tree order
  def parent_choices
    @parent_choices ||= begin
      subtree = [ @unit, *@overview.descendants_of(@unit) ]
      @overview.in_tree_order.select do |unit|
        may_sit_under?(unit) && subtree.exclude?(unit) && @policy.create_unit?(unit)
      end
    end
  end

  # Where the unit may move into another structure, the organisation's
  # included, changing its type and those its structure governs on the way
  # ([#521](https://github.com/espaliahq/espalia/issues/521)). A unit with a structure of its own takes a type and keeps
  # its structure. Each needs the right to change both structures.
  #
  # @return [Array<OrgUnit>] in tree order
  def conversion_parent_choices
    @conversion_parent_choices ||= begin
      from = @overview.structure_unit_of(@unit)
      if !may_cross_from?(from)
        []
      else
        subtree = [ @unit, *@overview.descendants_of(@unit) ]
        @overview.in_tree_order.select do |unit|
          into = @overview.structure_beneath(unit)
          into != from && subtree.exclude?(unit) && @policy.create_unit?(unit) && may_edit_structure?(into)
        end
      end
    end
  end

  # Whether the unit may move out of a unit's own structure to the top of the
  # organisation's, taking a type that may sit there ([#521](https://github.com/espaliahq/espalia/issues/521)).
  #
  # @return [Boolean]
  def root_conversion_choice?
    return @root_conversion_choice if defined?(@root_conversion_choice)

    from = @overview.structure_unit_of(@unit)
    @root_conversion_choice = !from.nil? && may_cross_from?(from) && may_edit_structure?(nil) && @policy.create_unit?(nil) &&
                              @overview.taxonomy_of(nil).kinds.any? { it.provider == OrgGraph::Taxonomy::ESPALIA && it.top? }
  end

  # @return [Boolean] whether the unit may sit at the root
  def root_choice?
    @overview.structure_unit_of(@unit).nil? && @overview.taxonomy.may_be_top?(@unit.level_id) && @policy.create_unit?(nil)
  end

  # @param membership [OrgMembership]
  # @return [Boolean] whether the viewer may move or remove it
  def member?(membership)
    membership.provider == OrgGraph::StructureAggregate::ESPALIA &&
      @policy.edit_membership?(membership.person, @unit)
  end

  # @param membership [OrgMembership]
  # @return [Array<OrgUnit>] the units the viewer may move it to, in tree order
  def destinations(membership)
    return [] unless member?(membership)

    @overview.in_tree_order.select do |unit|
      unit != @unit && @policy.move_membership?(membership.person, @unit, unit)
    end
  end

  # Retire, merge or split. An HRIS that mirrors the unit holds its shape.
  #
  # @return [Boolean]
  def reshape? = @unit.held_by_espalia? && @policy.edit_unit?(@unit)

  # @return [Boolean]
  def split? = reshape? && @policy.create_unit?(@unit.parent)

  # @return [Boolean]
  def merge? = reshape? && merge_targets.any?

  # The units it may merge into: any other live unit outside its subtree
  # that Espalia holds and the viewer may edit.
  #
  # @return [Array<OrgUnit>] in tree order
  def merge_targets
    @merge_targets ||= begin
      subtree = [ @unit, *@overview.descendants_of(@unit) ]
      @overview.in_tree_order.select do |unit|
        subtree.exclude?(unit) && unit.held_by_espalia? && @policy.edit_unit?(unit)
      end
    end
  end

  private

  # An HRIS keeps the type of a unit it supplies, so none may convert.
  def may_cross_from?(from)
    rename? && @overview.converted_with(@unit).all?(&:held_by_espalia?) && may_edit_structure?(from)
  end

  def may_edit_structure?(structure_unit_id) = @policy.edit_structure_of?(structure_unit_id && @overview.unit(structure_unit_id))

  def may_sit_under?(unit)
    return false unless @overview.structure_beneath(unit) == @overview.structure_unit_of(@unit)

    parent_kind = @overview.seated_parent_kind(unit)
    taxonomy = @overview.taxonomy(@unit)
    parent_kind ? taxonomy.allows?(@unit.level_id, beneath: parent_kind) : taxonomy.may_be_top?(@unit.level_id)
  end
end
