# frozen_string_literal: true

# The Org Graph's settings (#126): where its facts and levels come from, on
# the left, and who may change it, on the right. Stacked on a phone.
class Views::Tenant::OrgGraph::SettingsView < Views::Base
  # @param sources [Hash] as Operations::OrgGraph::Sources returns it
  # @param editors [Hash] as Operations::OrgGraph::Editors returns it
  # @param editor_candidates [Array<Person>]
  # @param can_edit_taxonomy [Boolean] whether the viewer may add and move levels
  # @param forgetting_key_set [Boolean] whether this server holds the key forgetting needs
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(sources:, editors:, editor_candidates:, forgetting_key_set:, can_edit_taxonomy: false, user:, current_tenant:, tenants: [])
    @sources = sources
    @editors = editors
    @editor_candidates = editor_candidates
    @forgetting_key_set = forgetting_key_set
    @can_edit_taxonomy = can_edit_taxonomy
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :org_graph, user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      a(href: tenant_org_graph_path, class: "text-sm text-muted hover:text-default transition-colors") { "← Org Graph" }
      h1(class: "mt-2 text-2xl font-bold text-default") { "Org Graph settings" }
      p(class: "mt-1 text-sm text-muted") do
        "Where the Org Graph's facts come from, how long it keeps them, and who may change it. Tenant admins only."
      end

      div(class: "mt-6 grid gap-6 lg:grid-cols-3") do
        div(class: "lg:col-span-2 space-y-6 min-w-0") do
          render Views::Tenant::OrgGraph::Settings::SourcesPanel.new(hris: @sources[:hris], facts: @sources[:facts])
          render Views::Tenant::OrgGraph::Settings::LevelsPanel.new(
            hris: @sources[:hris], levels: @sources[:levels], can_edit_taxonomy: @can_edit_taxonomy
          )
          render Views::Tenant::OrgGraph::Settings::HandoverPanel.new(hris: @sources[:hris], levels: @sources[:levels])
        end
        div(class: "space-y-6 min-w-0") do
          render Views::Tenant::OrgGraph::Settings::EditorsPanel.new(editors: @editors, candidates: @editor_candidates)
          render Views::Tenant::OrgGraph::Settings::FreshnessPanel.new(freshness: @sources[:freshness])
          render Views::Tenant::OrgGraph::Settings::ForgettingPanel.new(
            config: @current_tenant.org_graph_config, key_set: @forgetting_key_set
          )
        end
      end
    end
  end
end
