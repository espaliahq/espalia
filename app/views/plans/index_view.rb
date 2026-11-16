# frozen_string_literal: true

# The plans a person is in (#226), and a form to start one for those who may.
# The list comes from `team_planning_plans`, so it holds the caller's own
# plans and no others.
class Views::Plans::IndexView < Views::Base
  # @param plans [Array<Hash>] from `team_planning_plans`
  # @param archived [Boolean] whether the list holds the archived plans rather than the live ones
  # @param can_create [Boolean] whether the caller may start a plan
  # @param error [String, nil] why the last plan could not be created
  # @param draft [Hash] the name, base date and scope the caller last chose, kept when the create was refused
  # @param units [Array<Hash>] from `team_planning_coverable_units`, the units a new plan may cover
  def initialize(plans:, can_create:, user:, current_tenant:, tenants: [], archived: false, error: nil, draft: {}, units: [])
    @plans = plans
    @archived = archived
    @units = units
    @can_create = can_create
    @error = error
    @draft = draft
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::PageLayout.new(user: @user, current_tenant: @current_tenant, tenants: @tenants) do
      div(class: "w-full max-w-4xl mx-auto px-4 sm:px-6 py-8 space-y-6") do
        div do
          h1(class: "text-xl font-bold text-default") { "Planning" }
          p(class: "mt-1 text-sm text-muted") do
            "Try out changes to your organisation without touching it. Each plan is private to the people in it."
          end
        end
        @plans.any? ? plan_list : empty
        new_plan_form if @can_create && !@archived
      end
    end
  end

  private

  def plan_list
    section(aria: { labelledby: "your-plans" }) do
      div(class: "mb-3 flex flex-wrap items-center justify-between gap-2") do
        h2(id: "your-plans", class: "text-base font-semibold text-default") { @archived ? "Your archived plans" : "Your plans" }
        state_switch
      end
      render Components::Kit::Card.new(variant: :flush) do |card|
        card.body do
          ul(class: "divide-y divide-subtle") { @plans.each { plan_row(it) } }
        end
      end
    end
  end

  def plan_row(plan)
    li(class: "flex flex-wrap items-center justify-between gap-x-4 gap-y-1 px-4 py-3") do
      div(class: "min-w-0") do
        a(href: plan_path(plan[:plan_id]), class: "font-medium text-link underline break-words") { plan[:name] }
        p(class: "text-sm text-muted") { plan_dates(plan) }
      end
      render Components::Kit::Badge.new(plan[:role] == "editor" ? "Editor" : "Viewer")
    end
  end

  def plan_dates(plan)
    based = "Based on #{day(plan[:base_on])}"
    plan[:archived_on] ? "#{based}. Archived on #{day(plan[:archived_on])}" : based
  end

  def day(iso) = Date.iso8601(iso).strftime("%-d %B %Y")

  def state_switch
    render Components::Kit::SegmentedControl.new(label: "Which plans", size: :sm, touch: true) do |control|
      control.segment("Live", href: plans_path, selected: !@archived)
      control.segment("Archived", href: plans_path(state: "archived"), selected: @archived)
    end
  end

  def empty
    if @archived
      render Components::Kit::EmptyState.new(title: "No archived plans", size: :page) do
        p(class: "text-sm text-muted") { "An editor can archive a plan from its page to set it aside without deleting it." }
        div(class: "mt-4") { state_switch }
      end
    else
      render Components::Kit::EmptyState.new(title: "You're not in any plans yet", size: :page) do
        p(class: "text-sm text-muted") do
          @can_create ? "Start one below, then add the people you want to plan with." : "When someone adds you to a plan, it appears here."
        end
        div(class: "mt-4") { state_switch }
      end
    end
  end

  def new_plan_form
    section(aria: { label: "New plan" }) do
      render Components::Kit::Card.new(title: "New plan", heading_level: :h2) do |card|
        card.body do
          render Components::Kit::Alert.new(tone: :danger, class: "mb-4") { @error } if @error
          form(action: plans_path, method: "post", class: "space-y-4") do
            input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
            div(class: "grid gap-4 sm:grid-cols-[1fr_auto]") { name_and_date }
            render Views::Plans::ScopeFields.new(id: "plan-scope", units: @units, chosen: drafted_units, choosing: @draft[:scope] == "chosen",
                                                 hint: "You can widen what a plan covers later.")
            render Components::Kit::Button.new(variant: :solid, tone: :brand, type: :submit) { "Create plan" }
          end
        end
      end
    end
  end

  def name_and_date
    div do
      label(for: "plan_name", class: "block text-sm font-medium text-default") { "Name" }
      input(id: "plan_name", name: "plan[name]", type: "text", required: true, value: @draft[:name], class: "mt-1 w-full #{Components::Kit::Field::INPUT}")
    end
    div do
      label(for: "plan_base_on", class: "block text-sm font-medium text-default") { "Start from the organisation on" }
      input(id: "plan_base_on", name: "plan[base_on]", type: "date", required: true,
            value: @draft[:base_on].presence || Date.current.iso8601, class: "mt-1 w-full #{Components::Kit::Field::INPUT}")
    end
  end

  def drafted_units
    return [] unless @draft[:scope] == "chosen"

    Array(@draft[:unit_ids]).map { { unit_id: it } }
  end
end
