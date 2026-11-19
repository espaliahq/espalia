# frozen_string_literal: true

# Moves a unit into another structure ([#494](https://github.com/espaliahq/espalia/issues/494), [#521](https://github.com/espaliahq/espalia/issues/521)): it and every unit
# its structure governs change type on the way, so the step asks what each
# type becomes. A type the units last held in the structure they join comes
# preselected, so a move back puts each where it was.
class Views::Tenant::OrgGraph::StructureMoveStep < Views::Tenant::OrgGraph::StructureStep
  # @param parent [OrgUnit, nil] where it moves
  # @param to_top [Boolean] whether it moves to the top of the organisation's
  #   structure; a parent that is no longer live never means the top
  def initialize(parent:, to_top:, **)
    super(**)
    @parent = parent
    @to_top = to_top
  end

  private

  def title = "Move #{@unit.name}"

  def allowed? = @to_top ? @rights.root_conversion_choice? : @rights.conversion_parent_choices.include?(@parent)

  def not_allowed_because = "#{@unit.name} can't move into another structure from here. Choose a parent in its drawer."

  def from_id = @overview.structure_unit_of(@unit)

  def into_id = @overview.structure_beneath(@parent)

  def into_kinds = @overview.taxonomy_of(into_id).kinds.select { it.provider == ::OrgGraph::Taxonomy::ESPALIA }

  def body
    moved = @overview.converted_with(@unit)
    taken = moved.one? ? "it" : "it and the #{moved.size - 1} #{'unit'.pluralize(moved.size - 1)} beneath it"
    changes = moved.one? ? "it changes" : "each changes"
    p(class: "text-sm text-default") do
      if @parent
        "Moving #{@unit.name} under #{@parent.name} takes #{taken} out of #{structure_name(from_id)} " \
          "into #{structure_name(into_id)}, so #{changes} type."
      else
        "Moving #{@unit.name} to the top of #{structure_name(nil)} takes #{taken} out of #{structure_name(from_id)}, so #{changes} type."
      end
    end
    keeping(moved)
    step_form(tenant_org_unit_structure_move_path(@unit), class: "space-y-4") do
      input(type: "hidden", name: "parent_id", value: @parent&.id.to_s)
      conversion_fieldset(moved, "Each type in #{structure_name(from_id)} becomes a type in #{structure_name(into_id)}") do |type, id|
        kinds = type.id == @unit.level_id ? own_kinds : into_kinds
        type_select("conversion[#{type.id}]", id, kinds, selected: previous_type(moved, type, kinds) || same_name(type, kinds))
      end
      date_field
      submit(title)
    end
  end

  def keeping(moved)
    declaring = moved.select { @overview.declares_structure?(it) }
    return if declaring.empty?

    p(class: "text-sm text-muted") do
      "#{declaring.map(&:name).to_sentence} #{declaring.one? ? 'keeps its' : 'keep their'} own structure, " \
        "and the units in it keep their types."
    end
  end

  # The types the unit itself may take where it lands. The command refuses
  # the rest; when none fits, the full list lets it say why.
  def own_kinds
    taxonomy = @overview.taxonomy_of(into_id)
    parent_kind = @overview.seated_parent_kind(@parent)
    fitting = into_kinds.select { parent_kind ? taxonomy.allows?(it.id, beneath: parent_kind) : it.top? }
    fitting.presence || into_kinds
  end

  # The type of the structure it joins that every unit of this type held
  # there last, when each held one and they agree.
  def previous_type(moved, type, kinds)
    @held ||= @overview.last_held_among(moved, into_kinds)
    held = moved.select { it.level_id == type.id }.map { @held[it.id] }.uniq
    held.sole if held.one? && kinds.any? { it.id == held.sole }
  end
end
