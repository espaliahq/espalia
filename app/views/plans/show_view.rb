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

  # The side panel's choice, remembered per person on their device.
  PANEL_COOKIE = "plan_side_panel_open"
  PANEL_URL_KEY = "panel"

  # @param plan [Hash] from `team_planning_plan`
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`
  # @param members [Array<Hash>] from `team_planning_plan_members`
  # @param tabs [Array<Tab>] shown only when there is more than one
  # @param open_tab [Symbol] the key of the tab the body belongs to
  # @param body [Phlex::SGML, nil] the open tab's content; the scenario table when nil
  # @param actions [Array<Phlex::SGML>] buttons beside the plan's name
  # @param panels [Array<Phlex::SGML>] sidebar panels; the rules and the members when nil
  # @param drawer [Phlex::SGML, nil] a component that renders a drawer over the page
  # @param can_edit [Boolean] whether the viewer may fork and rename scenarios; never on an archived plan
  # @param can_archive [Boolean] whether the viewer may archive the plan
  # @param can_restore [Boolean] whether the viewer may restore the archived plan
  # @param can_delete [Boolean] whether the viewer may delete the plan
  # @param see_pay [Hash] the members panel's see-pay options: `can_manage_see_pay`, `reachable_ids`, `locked_out`
  # @param coverable_units [Array<Hash>, nil] from `team_planning_coverable_units`, for an editor to change the scope
  # @param panel_open [Boolean] whether the side panel renders open; see `.panel_open?`
  def initialize(plan:, scenarios:, members:, user:, current_tenant:, tenants: [], tabs: nil, open_tab: :scenarios,
                 body: nil, actions: [], panels: nil, drawer: nil, can_edit: false, can_archive: false, can_restore: false, can_delete: false,
                 see_pay: {}, coverable_units: nil, panel_open: true)
    @panel_open = panel_open
    @plan = plan
    @can_archive = can_archive
    @can_restore = can_restore
    @can_delete = can_delete
    @coverable_units = coverable_units
    @see_pay = see_pay
    @can_edit = can_edit
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
      div(class: "w-full px-4 sm:px-6 py-8", data: ({ controller: "modal", action: "keydown.esc@window->modal#escape" } if @can_edit || @can_archive || @can_delete)) do
        header
        frozen_notice if @plan[:frozen]
        archived_notice if @plan[:archived]
        div(class: "mt-6") do
          render Components::Kit::SidePanel.new(id: "plan-side-panel", title: "About this plan", open: @panel_open,
                                                cookie: PANEL_COOKIE, url_key: PANEL_URL_KEY, narrow: :stack) do |panel|
            panel.main do
              section(aria: { labelledby: "plan-main-heading" }) do
                tab_strip(panel)
                render(@body || Views::Plans::ScenarioTable.new(plan_id: @plan[:plan_id], scenarios: @scenarios, can_edit: @can_edit))
              end
            end
            panel.body { (@panels || default_panels).each { render it } }
          end
        end
        render Views::Plans::ScenarioDialogs.new(plan_id: @plan[:plan_id], scenarios: @scenarios) if @can_edit
        render Views::Plans::ScopeDialog.new(plan: @plan, units: @coverable_units) if changes_scope?
        render Views::Plans::ArchiveDialog.new(plan_id: @plan[:plan_id]) if @can_archive
        render Views::Plans::DeleteDialog.new(plan: @plan) if @can_delete
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
        scope_line
      end
      if @actions.any? || @can_edit || @can_archive || @can_delete
        div(class: "flex flex-wrap items-center gap-2") do
          @actions.each { render it }
          if @can_archive
            render Components::Kit::Button.new(variant: :outline, data: Views::Plans::ArchiveDialog.trigger) { "Archive plan" }
          end
          if @can_delete
            render Components::Kit::Button.new(variant: :outline, tone: :danger, data: Views::Plans::DeleteDialog.trigger) { "Delete plan" }
          end
          new_scenario_button if @can_edit
        end
      end
    end
  end

  def new_scenario_button
    render Components::Kit::Button.new(tone: :brand, data: Views::Plans::ScenarioDialogs.fork_trigger(Views::Plans::ScenarioDialogs.default_parent(@plan[:plan_id], @scenarios))) do
      "New scenario"
    end
  end

  def scope_line
    p(class: "mt-1 flex flex-wrap items-center gap-x-2 text-sm text-muted") do
      span { "Covers #{Views::Plans::ScopeDialog.covers(@plan[:scope])}." }
      if changes_scope?
        render Components::Kit::Button.new(variant: :link, tone: :brand, compact: true, data: Views::Plans::ScopeDialog.trigger) { "Change" }
      end
    end
  end

  def changes_scope? = @can_edit && @coverable_units

  def privacy_line
    count = @members.size
    "Private to #{count} #{count == 1 ? 'member' : 'members'}. You're #{@plan[:role] == 'editor' ? 'an editor' : 'a viewer'}."
  end

  def frozen_notice
    render Components::Kit::Alert.new(tone: :warning, title: "This plan is frozen", class: "mt-4") do
      "None of its editors is still in the organisation, so nobody can change it. Its viewers can still read it."
    end
  end

  def archived_notice
    archived = @plan[:archived]
    title = "Archived on #{Date.iso8601(archived[:on]).strftime("%-d %B %Y")}#{" by #{archived[:by_name]}" if archived[:by_name]}"
    render Components::Kit::Alert.new(tone: :info, title:, class: "mt-4") do |alert|
      alert.action { restore_button } if @can_restore
      p { "Nobody can change this plan, and it isn't checked against the organisation, until an editor restores it." }
      p(class: "mt-1") { "Its costs, budgets and capacity still use today's pay bands, exchange rates and rules." }
    end
  end

  def restore_button
    form(action: restore_plan_path(@plan[:plan_id]), method: "post") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      render Components::Kit::Button.new(variant: :outline, size: :sm, type: :submit) { "Restore plan" }
    end
  end

  # Whether the side panel opens: as the viewer last left it, from the URL or
  # the cookie; otherwise closed on the map of a plan with scenarios, where the
  # map wants the width, and open on a new plan, whose rules and members come next.
  #
  # @param choice [String, nil] the URL's or the cookie's "open" or "closed"
  # @param open_tab [Symbol]
  # @param scenarios [Array<Hash>] the baseline first
  def self.panel_open?(choice:, open_tab:, scenarios:)
    return choice == "open" if %w[open closed].include?(choice)

    !(open_tab == :map && scenarios.size > 1)
  end

  def tab_strip(panel)
    if tabs.size > 1
      div(class: "mb-4 flex items-end gap-3 border-b border-default") do
        nav(aria: { label: "Plan views" }, class: "min-w-0 flex-1") do
          div(class: "-mb-px flex flex-wrap gap-x-1") { tabs.each { tab(it) } }
        end
        div(class: "shrink-0 pb-1.5") { panel.toggle }
      end
      h2(id: "plan-main-heading", class: "sr-only") { current_tab.label }
    else
      div(class: "mb-3 flex items-center justify-between gap-3") do
        h2(id: "plan-main-heading", class: "text-base font-semibold text-default") { current_tab.label }
        panel.toggle
      end
    end
  end

  def tab(tab)
    open = tab.key == @open_tab
    a(href: tab.href, aria: { current: ("page" if open) },
      class: "shrink-0 whitespace-nowrap border-b-2 px-2 py-2 text-sm font-medium sm:px-3 " \
             "#{open ? 'border-brand text-default' : 'border-transparent text-muted hover:text-default'}") { tab.label }
  end

  def tabs = @tabs ||= @given_tabs || [ Tab.new(key: :scenarios, label: "Scenarios", href: plan_path(@plan[:plan_id])) ]

  def current_tab = tabs.find { it.key == @open_tab } || tabs.first

  def default_panels
    [ Views::Plans::RulesPanel.new, Views::Plans::MembersPanel.new(members: @members, plan_id: @plan[:plan_id], **@see_pay) ]
  end

  def base_on = Date.iso8601(@plan[:base_on])
end
