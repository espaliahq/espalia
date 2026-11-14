# frozen_string_literal: true

# The plans a person is in (#226), and a form to start one for those who may.
# The list comes from `team_planning_plans`, so it holds the caller's own
# plans and no others.
class Views::Plans::IndexView < Views::Base
  # @param plans [Array<Hash>] from `team_planning_plans`
  # @param can_create [Boolean] whether the caller may start a plan
  # @param error [String, nil] why the last plan could not be created
  def initialize(plans:, can_create:, user:, current_tenant:, tenants: [], error: nil)
    @plans = plans
    @can_create = can_create
    @error = error
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
        new_plan_form if @can_create
      end
    end
  end

  private

  def plan_list
    section(aria: { labelledby: "your-plans" }) do
      h2(id: "your-plans", class: "mb-3 text-base font-semibold text-default") { "Your plans" }
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
        p(class: "text-sm text-muted") { "Based on #{Date.iso8601(plan[:base_on]).strftime("%-d %B %Y")}" }
      end
      render Components::Kit::Badge.new(plan[:role] == "editor" ? "Editor" : "Viewer")
    end
  end

  def empty
    render Components::Kit::EmptyState.new(title: "You're not in any plans yet", size: :page) do
      p(class: "text-sm text-muted") do
        @can_create ? "Start one below, then add the people you want to plan with." : "When someone adds you to a plan, it appears here."
      end
    end
  end

  def new_plan_form
    section(aria: { labelledby: "new-plan" }) do
      render Components::Kit::Card.new(title: "New plan", heading_level: :h2) do |card|
        card.body do
          render Components::Kit::Alert.new(tone: :danger, class: "mb-4") { @error } if @error
          form(action: plans_path, method: "post", class: "grid gap-4 sm:grid-cols-[1fr_auto_auto] sm:items-end") do
            input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
            div do
              label(for: "plan_name", class: "block text-sm font-medium text-default") { "Name" }
              input(id: "plan_name", name: "plan[name]", type: "text", required: true, class: "mt-1 w-full #{Components::Kit::Field::INPUT}")
            end
            div do
              label(for: "plan_base_on", class: "block text-sm font-medium text-default") { "Start from the organisation on" }
              input(id: "plan_base_on", name: "plan[base_on]", type: "date", required: true,
                    value: Date.current.iso8601, class: "mt-1 w-full #{Components::Kit::Field::INPUT}")
            end
            render Components::Kit::Button.new(variant: :solid, tone: :brand, type: :submit) { "Create plan" }
          end
        end
      end
    end
  end
end
