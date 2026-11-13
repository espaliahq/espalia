# frozen_string_literal: true

# The Org Graph's settings (#126): where its facts and levels come from, on
# the left, and who may change it, on the right. Stacked on a phone.
class Views::Tenant::OrgGraph::SettingsView < Views::Base
  # @param editors [Hash] as Operations::OrgGraph::Editors returns it
  # @param editor_candidates [Array<Person>]
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(editors:, editor_candidates:, user:, current_tenant:, tenants: [])
    @editors = editors
    @editor_candidates = editor_candidates
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
        div(class: "lg:col-span-2 space-y-6 min-w-0")
        div(class: "space-y-6 min-w-0") do
          render Views::Tenant::OrgGraph::Settings::EditorsPanel.new(editors: @editors, candidates: @editor_candidates)
        end
      end
    end
  end
end
