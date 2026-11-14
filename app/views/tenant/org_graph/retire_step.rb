# frozen_string_literal: true

# Retires a unit (#138), after saying whose memberships end.
class Views::Tenant::OrgGraph::RetireStep < Views::Tenant::OrgGraph::UnitStep
  private

  def title = "Retire #{@unit.name}"

  def allowed? = true

  def body
    count = memberships.size
    if count.zero?
      p(class: "text-sm text-default") { "No one is in #{@unit.name}, so no memberships end." }
    else
      p(id: "org-unit-retire-summary", class: "text-sm text-default") do
        "Retiring #{@unit.name} ends #{count} #{'membership'.pluralize(count)}. " \
          "#{count == 1 ? 'This person' : 'These people'} will be in no team unless they belong to another:"
      end
      people_list(memberships, label: "People leaving #{@unit.name}")
    end
    step_form(tenant_org_unit_retirement_path(@unit), class: "space-y-4") do
      date_field
      submit("Retire #{@unit.name}", tone: :danger)
    end
  end
end
