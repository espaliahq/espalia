# frozen_string_literal: true

# Lists all tenant memberships (TenantUser) in the current tenant.
#
# Each row links to the per-user detail page where tenant role and
# framework collaborator assignments can be managed.
#
class Views::Tenant::Users::IndexView < Views::Base
  # @param tenant_users [Array<TenantUser>]
  # @param collaborator_counts [Hash{String => Integer}] person_id → count
  # @param impersonatable_ids [Set<String>] TenantUser ids the admin may "view as"
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(tenant_users:, collaborator_counts:,
                 impersonatable_ids: Set.new,
                 user: nil, current_tenant: nil, tenants: [])
    @tenant_users = tenant_users
    @collaborator_counts = collaborator_counts
    @impersonatable_ids = impersonatable_ids
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :users,
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      page_header
      table_card
    end
  end

  private

  def page_header
    count = @tenant_users.size
    render Components::Kit::SectionHeading.new(
      "Tenant users",
      subtitle: "#{count} #{'member'.pluralize(count)} in this tenant"
    )
  end

  def table_card
    if @tenant_users.any?
      render Components::Kit::Card.new(variant: :flush) do |card|
        card.body { table_body }
      end
    else
      empty_state
    end
  end

  def table_body
    div(class: "overflow-x-auto") do
      table(class: "min-w-full divide-y divide-gray-200 dark:divide-gray-700") do
        thead(class: "bg-gray-50 dark:bg-gray-900/50") do
          tr do
            th_label "Name"
            th_label "Email"
            th_label "Tenant role"
            th_label "Linked person"
            th_label "Framework involvement"
            th_label "View as"
          end
        end
        tbody(class: "divide-y divide-gray-200 dark:divide-gray-700 " \
                     "bg-white dark:bg-gray-800") do
          @tenant_users.each { |tu| table_row(tu) }
        end
      end
    end
  end

  def table_row(tenant_user)
    tr(class: "hover:bg-gray-50 dark:hover:bg-gray-900/30") do
      cell do
        a(href: tenant_user_path(tenant_user),
          class: "font-medium text-primary-ink hover:underline") { display_name(tenant_user) }
      end
      cell { tenant_user.user.email }
      cell { role_badge(tenant_user) }
      cell { person_status(tenant_user) }
      cell { collaborator_count_text(tenant_user) }
      cell { impersonate_action(tenant_user) }
    end
  end

  # "View as" affordance — a small POST form to start impersonation. Only
  # rendered for memberships the acting admin is authorised to impersonate
  # (computed server-side via ImpersonationPolicy); everyone else gets a
  # muted dash so the column stays aligned.
  def impersonate_action(tenant_user)
    unless @impersonatable_ids.include?(tenant_user.id)
      return span(class: "text-gray-300 dark:text-gray-600") { "—" }
    end

    form(action: impersonation_path, method: "post") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "tenant_user_id", value: tenant_user.id)
      button(
        type: "submit",
        aria: { label: "View as #{display_name(tenant_user)}" },
        class: "rounded-md border border-gray-300 dark:border-gray-600 px-2.5 py-1 text-xs " \
               "font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-700 " \
               "focus:outline-hidden focus:ring-2 focus:ring-primary/40 cursor-pointer"
      ) { "View as" }
    end
  end

  def th_label(text)
    th(class: "px-4 py-3 text-left text-xs font-medium uppercase tracking-wider " \
              "text-gray-600 dark:text-gray-300") { text }
  end

  def cell(&block)
    td(class: "px-4 py-3 text-sm text-gray-900 dark:text-gray-100", &block)
  end

  def display_name(tenant_user)
    tenant_user.person&.name.presence ||
      TenantUser.derive_person_name(tenant_user.user.email)
  end

  def role_badge(tenant_user)
    if tenant_user.admin?
      render Components::Kit::Badge.new("Admin", variant: :primary)
    else
      render Components::Kit::Badge.new("Member", variant: :default)
    end
  end

  def person_status(tenant_user)
    person = tenant_user.person
    if person.nil?
      span(class: "text-gray-600 dark:text-gray-300") { "Not linked" }
    elsif person.status == "active"
      render Components::Kit::Badge.new("Active", variant: :success)
    else
      render Components::Kit::Badge.new(person.status.to_s.humanize, variant: :default)
    end
  end

  def collaborator_count_text(tenant_user)
    count = tenant_user.person_id ? (@collaborator_counts[tenant_user.person_id] || 0) : 0
    if count.positive?
      span { "#{count} #{'assignment'.pluralize(count)}" }
    else
      span(class: "text-gray-600 dark:text-gray-300") { "None" }
    end
  end

  def empty_state
    render Components::Kit::Card.new do |card|
      card.body do
        p(class: "text-sm text-gray-600 dark:text-gray-300 text-center py-6") do
          "No tenant members yet."
        end
      end
    end
  end
end
