# frozen_string_literal: true

# One plan's page (#226): its scenarios in the main column, and what the plan
# holds beside them.
#
# Later stories fill slots rather than reshape the page. The controller hands
# in header actions (new scenario, 3.11), tabs over the main column with the
# body of the open one (the map, the changes and the checks tabs), sidebar
# panels, and a drawer, as the Org Graph's Units view takes its drawer and
# sidebar.
class Views::Plans::ShowView < Views::Base
  # A tab over the main column. The page marks the one whose key is open.
  Tab = Data.define(:key, :label, :href)

  # @param plan [Hash] from `team_planning_plan`
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`
  # @param members [Array<Hash>] from `team_planning_plan_members`
  # @param tabs [Array<Tab>] shown only when there is more than one
  # @param open_tab [Symbol] the key of the tab the body belongs to
  # @param body [Phlex::SGML, nil] the open tab's content; the scenario table when nil
  # @param actions [Array<Phlex::SGML>] buttons beside the plan's name
  # @param panels [Array<Phlex::SGML>] sidebar panels; the rules and the members when nil
  # @param drawer [Phlex::SGML, nil] a component that renders a drawer over the page
  def initialize(plan:, scenarios:, members:, user:, current_tenant:, tenants: [], tabs: nil, open_tab: :scenarios,
                 body: nil, actions: [], panels: nil, drawer: nil)
    @plan = plan
    @scenarios = scenarios
    @members = members
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
    @given_tabs = tabs
    @open_tab = open_tab
    @body = body
    @actions = actions
    @panels = panels
    @drawer = drawer
  end

  def view_template
    render Components::Shell::PageLayout.new(user: @user, current_tenant: @current_tenant, tenants: @tenants) do
      div(class: "w-full px-4 sm:px-6 py-8") do
        header
        frozen_notice if @plan[:frozen]
        div(class: "mt-6 flex flex-col lg:flex-row gap-6") do
          section(class: "flex-1 min-w-0", aria: { labelledby: "plan-main-heading" }) do
            tab_strip
            render(@body || Views::Plans::ScenarioTable.new(scenarios: @scenarios, base_on: base_on))
          end
          aside(class: "w-full lg:w-80 shrink-0 space-y-6", aria: { label: "About this plan" }) do
            (@panels || default_panels).each { render it }
          end
        end
      end
      render @drawer if @drawer
    end
  end

  private

  def header
    div(class: "flex flex-wrap items-start justify-between gap-x-4 gap-y-3") do
      div(class: "min-w-0") do
        nav(aria: { label: "Breadcrumb" }, class: "text-sm") do
          a(href: plans_path, class: "text-link underline") { "Planning" }
        end
        h1(class: "mt-1 text-xl font-bold text-default break-words") { @plan[:name] }
        p(class: "mt-1 flex flex-wrap items-center gap-2 text-sm text-muted") do
          span { privacy_line }
          render Components::Kit::Badge.new("Based on the Org Graph on #{base_on.strftime("%-d %B %Y")}", tone: :warning)
        end
      end
      div(class: "flex flex-wrap items-center gap-2") { @actions.each { render it } } if @actions.any?
    end
  end

  def privacy_line
    count = @members.size
    "Private to #{count} #{count == 1 ? 'member' : 'members'}. You're #{@plan[:role] == 'editor' ? 'an editor' : 'a viewer'}."
  end

  def frozen_notice
    render Components::Kit::Alert.new(tone: :warning, title: "This plan is frozen", class: "mt-4") do
      "None of its editors is still in the organisation, so nobody can change it. Its viewers can still read it."
    end
  end

  def tab_strip
    if tabs.size > 1
      nav(aria: { label: "Plan views" }, class: "mb-4 flex gap-1 border-b border-default") do
        tabs.each { tab(it) }
      end
    end
    h2(id: "plan-main-heading", class: ("sr-only" if tabs.size > 1) || "mb-3 text-base font-semibold text-default") do
      current_tab.label
    end
  end

  def tab(tab)
    open = tab.key == @open_tab
    a(href: tab.href, aria: { current: ("page" if open) },
      class: "-mb-px border-b-2 px-3 py-2 text-sm font-medium " \
             "#{open ? 'border-brand text-default' : 'border-transparent text-muted hover:text-default'}") { tab.label }
  end

  def tabs = @tabs ||= @given_tabs || [ Tab.new(key: :scenarios, label: "Scenarios", href: plan_path(@plan[:plan_id])) ]

  def current_tab = tabs.find { it.key == @open_tab } || tabs.first

  def default_panels
    [ Views::Plans::RulesPanel.new, Views::Plans::MembersPanel.new(members: @members) ]
  end

  def base_on = Date.iso8601(@plan[:base_on])
end
