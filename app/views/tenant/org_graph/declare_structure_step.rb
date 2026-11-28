# frozen_string_literal: true

# Gives a unit a structure of its own ([#494](https://github.com/espaliahq/espalia/issues/494)): fresh, or a copy of the
# structure in force where it sits. Each type held beneath it takes a type
# of the new structure; the unit keeps its own.
class Views::Tenant::OrgGraph::DeclareStructureStep < Views::Tenant::OrgGraph::StructureStep
  # @param fresh [Boolean] start from new types rather than a copy
  def initialize(fresh: false, **)
    super(**)
    @fresh = fresh
  end

  private

  def title = "Give #{@unit.name} its own structure"

  def allowed? = !@overview.declares_structure?(@unit)

  def not_allowed_because = "#{@unit.name} has its own structure already."

  def governed = @governed ||= @overview.governed_by(@unit)

  def source_id = @overview.structure_unit_of(@unit)

  def source_kinds = @overview.taxonomy_of(source_id).kinds

  def body
    p(class: "text-sm text-default") do
      "The units beneath #{@unit.name} will use #{@unit.name}'s own unit types, and all change to them together. " \
        "#{@unit.name} keeps its own type."
    end
    source_choice
    step_form(tenant_org_unit_structure_declaration_path(@unit), class: "space-y-4", data: { turbo: "false" }) do
      input(type: "hidden", name: "start", value: @fresh ? "fresh" : "copy")
      @fresh ? fresh_fields : copy_fields
      change_count(governed) if governed.any?
      date_field
      submit(title)
    end
  end

  def source_choice
    render Components::Kit::SegmentedControl.new(label: "Start from", size: :md) do |control|
      control.segment("A copy of #{structure_name(source_id)}", short: "A copy", href: step_path(fresh: nil), selected: !@fresh)
      control.segment("New types", href: step_path(fresh: "1"), selected: @fresh)
    end
  end

  def step_path(fresh:)
    new_tenant_org_unit_structure_declaration_path(@unit, on: @effective_on, fresh:, **compared)
  end

  def copy_fields
    p(id: "org-unit-structure-copy", class: "text-sm text-muted") do
      "It starts with the types in #{structure_name(source_id)}, and where each can sit: #{source_kinds.map(&:name).to_sentence}."
    end
    return no_units if governed.empty?

    conversion_fieldset(governed, "Each type beneath #{@unit.name} becomes") do |type, id|
      type_select("conversion[#{type.id}]", id, source_kinds, selected: type.id)
    end
  end

  def fresh_fields
    p(id: "org-unit-structure-permissive", class: "text-sm text-muted") do
      "Every type can sit anywhere in it for now. Narrow that on the next page."
    end
    if governed.empty?
      no_units
      div do
        label(for: "org-unit-new-type", class: "block text-sm font-medium text-default") { "Its first unit type" }
        input(type: "text", id: "org-unit-new-type", name: "names[]", required: true, autocomplete: "off",
              class: "#{Components::Kit::Field::INPUT} mt-1 w-full")
      end
    else
      conversion_fieldset(governed, "Name the type each becomes. Give two the same name to make them one.") do |type, id|
        input(type: "text", id:, name: "names[#{type.id}]", value: type.name, required: true, autocomplete: "off",
              class: "#{Components::Kit::Field::INPUT} w-full")
      end
    end
  end

  def no_units = p(class: "text-sm text-default") { "No unit sits beneath #{@unit.name} yet, so none changes type." }
end
