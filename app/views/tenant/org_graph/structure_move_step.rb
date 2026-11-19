# frozen_string_literal: true

# Moves a unit into another unit's own structure ([#494](https://github.com/espaliahq/espalia/issues/494)): it and every unit
# beneath it change type on the way, so the step asks what each type becomes.
class Views::Tenant::OrgGraph::StructureMoveStep < Views::Tenant::OrgGraph::StructureStep
  # @param parent [OrgUnit, nil] where it moves
  def initialize(parent:, **)
    super(**)
    @parent = parent
  end

  private

  def title = "Move #{@unit.name}"

  def allowed? = @parent && @rights.conversion_parent_choices.include?(@parent)

  def not_allowed_because = "#{@unit.name} can't move into another structure from here. Choose a parent in its drawer."

  def into_id = @overview.structure_beneath(@parent)

  def into_kinds = @overview.taxonomy_of(into_id).kinds.select { it.provider == ::OrgGraph::Taxonomy::ESPALIA }

  def body
    moved = [ @unit, *@overview.descendants_of(@unit) ]
    p(class: "text-sm text-default") do
      "Moving #{@unit.name} under #{@parent.name} puts #{moved.one? ? 'it' : "it and the #{moved.size - 1} #{'unit'.pluralize(moved.size - 1)} beneath it"} " \
        "in #{structure_name(into_id)}, so #{moved.one? ? 'it changes' : 'each changes'} type."
    end
    step_form(tenant_org_unit_structure_move_path(@unit), class: "space-y-4") do
      input(type: "hidden", name: "parent_id", value: @parent.id)
      conversion_fieldset(moved, "Each type becomes") do |type, id|
        type_select("conversion[#{type.id}]", id, into_kinds, selected: same_name(type, into_kinds))
      end
      date_field
      submit(title)
    end
  end
end
