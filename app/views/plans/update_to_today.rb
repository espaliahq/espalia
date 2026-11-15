# frozen_string_literal: true

# What updating a plan to today would take in, for an editor to confirm
# ([#337](https://github.com/espaliahq/espalia/issues/337)): the drift, where
# each scenario's planned changes stand, and the conflicts the update carries
# forward. It draws `team_planning_rebase_preview` and posts the base it read
# to `team_planning_rebase_plan`.
class Views::Plans::UpdateToToday < Views::Base
  # @param plan [Hash] from `team_planning_plan`
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`, baseline first
  # @param preview [Hash] from `team_planning_rebase_preview`
  def initialize(plan:, scenarios:, preview:)
    @plan = plan
    @scenarios = scenarios
    @preview = preview
  end

  def view_template
    section(aria: { labelledby: "update-to-today-heading" }, class: "space-y-6", data: { update_to_today: true }) do
      div do
        h3(id: "update-to-today-heading", class: "text-base font-semibold text-default") { "Update to today" }
        p(class: "mt-1 text-sm text-muted") do
          "The plan stands on #{day(@preview[:base_on])}. Updating moves its base to #{day(@preview[:to])}, so every " \
            "scenario reads the Org Graph as it is today. Nothing planned is rewritten, and a base only moves forward."
        end
      end
      drift_line
      scenario_counts
      carried_conflicts
      confirm
    end
  end

  private

  def plan_id = @plan[:plan_id]

  def drift_line
    count = @preview[:drift][:changes].size
    p(class: "text-sm text-default", data: { update_drift: count }) do
      if count.zero?
        plain "The Org Graph has learned nothing since the base."
      else
        plain "It takes in #{count} #{count == 1 ? 'change' : 'changes'} the Org Graph has learned since the base, as the "
        a(href: changes_plan_path(plan_id), class: "text-link underline") { "Changes tab" }
        plain " lists them."
      end
    end
  end

  def scenario_counts
    div do
      h4(class: "text-sm font-semibold text-default") { "Where each scenario's changes stand" }
      ul(class: "mt-2 divide-y divide-default rounded-lg border border-default bg-default") do
        @preview[:scenarios].each { scenario_row(it) }
      end
    end
  end

  def scenario_row(counts)
    li(class: "flex flex-col gap-1 p-3 sm:flex-row sm:items-center sm:justify-between", data: { update_scenario: counts[:scenario_id] }) do
      span(class: "min-w-0 text-sm font-medium text-default break-words") { scenario_name(counts[:scenario_id]) }
      div(class: "flex flex-wrap items-center gap-1.5") do
        render Components::Kit::Badge.new("#{counts[:done]} done", tone: :success)
        render Components::Kit::Badge.new("#{counts[:pending]} pending", tone: :neutral)
        render Components::Kit::Badge.new("#{counts[:conflicting]} conflicting", tone: counts[:conflicting].positive? ? :danger : :neutral)
      end
    end
  end

  def carried_conflicts
    conflicts = @preview[:conflicts]
    div(data: { update_conflicts: conflicts.size }) do
      h4(class: "text-sm font-semibold text-default") { "Conflicts it carries forward" }
      if conflicts.empty?
        p(class: "mt-1 text-sm text-muted") { "No planned change conflicts with the Org Graph, so none is carried forward." }
      else
        p(class: "mt-1 text-sm text-muted") do
          "Once the base is today these would read pending, so the update keeps them conflicting until someone settles each one."
        end
        ul(class: "mt-2 divide-y divide-default rounded-lg border border-default bg-default") do
          conflicts.each { conflict_row(it) }
        end
      end
    end
  end

  def conflict_row(conflict)
    li(class: "p-3 text-sm text-default break-words", data: { update_conflict: conflict[:facet] }) do
      strong(class: "font-medium") { @preview[:names].fetch(conflict[:subject_id], Views::Plans::ChangesTab::PLAN_ONLY) }
      plain " · #{Views::Plans::ChangesTab::FACETS.fetch(conflict[:facet], conflict[:facet].humanize)} in "
      a(href: changes_plan_path(plan_id, scenario: scenario_param(conflict[:scenario_id])), class: "text-link underline") do
        scenario_name(conflict[:scenario_id])
      end
    end
  end

  def confirm
    form(action: rebase_plan_path(plan_id), method: "post", class: "flex flex-wrap items-center gap-2") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "base_on", value: @preview[:base_on])
      render Components::Kit::Button.new(type: :submit) { "Update to #{day(@preview[:to])}" }
      render Components::Kit::Button.new(variant: :ghost, href: changes_plan_path(plan_id)) { "Cancel" }
    end
  end

  def scenario_name(id)
    return "Today" if id == plan_id

    @scenarios.find { it[:scenario_id] == id }&.dig(:name) || "A removed scenario"
  end

  def scenario_param(id) = (id unless id == plan_id)

  def day(value) = I18n.l(Date.iso8601(value), format: "%-d %b %Y")
end
