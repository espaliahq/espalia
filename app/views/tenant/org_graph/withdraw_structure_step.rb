# frozen_string_literal: true

# Withdraws a unit's own structure ([#494](https://github.com/espaliahq/espalia/issues/494)): the structure above governs the
# units beneath it again, and each type they hold takes a type of it.
class Views::Tenant::OrgGraph::WithdrawStructureStep < Views::Tenant::OrgGraph::StructureStep
  private

  def title = "Withdraw #{@unit.name}'s structure"

  def allowed? = @overview.declares_structure?(@unit)

  def not_allowed_because = "#{@unit.name} has no structure of its own."

  def above_id = @overview.structure_unit_of(@unit)

  def above_kinds = @overview.taxonomy_of(above_id).kinds.select { it.provider == ::OrgGraph::Taxonomy::ESPALIA }

  def body
    governed = @overview.governed_by(@unit)
    p(class: "text-sm text-default") do
      "The units beneath #{@unit.name} will use #{structure_name(above_id)} again, and all change type together. " \
        "Its own types stay in history."
    end
    step_form(tenant_org_unit_structure_withdrawal_path(@unit), class: "space-y-4") do
      if governed.any?
        conversion_fieldset(governed, "Each type beneath #{@unit.name} becomes") do |type, id|
          type_select("conversion[#{type.id}]", id, above_kinds, selected: same_name(type, above_kinds))
        end
        change_count(governed)
      else
        p(class: "text-sm text-default") { "No unit sits beneath #{@unit.name}, so none changes type." }
      end
      date_field
      submit(title, tone: :danger)
    end
  end
end
