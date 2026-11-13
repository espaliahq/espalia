# frozen_string_literal: true

# Merges a unit into another (#138): the viewer picks the unit that
# survives, and everyone moves to it.
class Views::Tenant::OrgGraph::MergeStep < Views::Tenant::OrgGraph::UnitStep
  SELECT_ID = "org-unit-merge-into"

  private

  def title = "Merge #{@unit.name}"

  def allowed? = @rights.merge?

  def body
    count = memberships.size
    p(class: "text-sm text-default") do
      moves = count.zero? ? "No one is in #{@unit.name}" : "#{people(count)} in #{@unit.name} move to it with their role and allocation"
      "Choose the unit that carries on. #{moves}, and #{@unit.name} retires."
    end
    people_list(memberships, label: "People moving from #{@unit.name}") if count.positive?
    step_form(tenant_org_unit_merge_path(@unit), class: "space-y-4") do
      div do
        label(for: SELECT_ID, class: "block text-sm font-medium text-default") { "Merge into" }
        select(id: SELECT_ID, name: "into_unit_id", required: true, class: "#{Components::Kit::Field::SELECT} mt-1 w-full") do
          option(value: "", disabled: true, selected: true) { "Choose a unit…" }
          @rights.merge_targets.each { |unit| unit_option(unit) }
        end
      end
      date_field
      submit("Merge #{@unit.name}", tone: :danger)
    end
  end
end
