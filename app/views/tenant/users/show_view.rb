# frozen_string_literal: true

# Per-user detail screen for tenant administrators.
#
# Section 1: identity + tenant role with promote/demote button.
# Section 2: framework collaborator assignments across all frameworks
# in the tenant. Slice 1 lists existing assignments read-only; the
# assignment form lands in slice 2.
#
class Views::Tenant::Users::ShowView < Views::Base
  # @param tenant_user [TenantUser]
  # @param person [Person]
  # @param collaborator_rows [Array<TenantUserCollaboratorRow>]
  # @param frameworks [Array<FrameworkState::Framework>]
  # @param last_admin [Boolean] true when this tenant_user is the only admin
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(tenant_user:, person:, collaborator_rows:, frameworks:,
                 last_admin:, user: nil, current_tenant: nil, tenants: [])
    @tenant_user = tenant_user
    @person = person
    @collaborator_rows = collaborator_rows
    @frameworks = frameworks
    @last_admin = last_admin
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :users,
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      back_link
      page_header
      div(class: "space-y-6") do
        identity_card
        collaborators_card
      end
    end
  end

  private

  def back_link
    div(class: "mb-4") do
      a(href: tenant_users_path,
        class: "text-sm text-gray-600 dark:text-gray-300 hover:underline") do
        plain "← All tenant users"
      end
    end
  end

  def page_header
    render Components::Kit::SectionHeading.new(
      display_name, subtitle: @tenant_user.user.email
    )
  end

  def identity_card
    render Components::Kit::Card.new(title: "Tenant role") do |card|
      card.body do
        div(class: "flex items-center justify-between") do
          current_role_summary
          role_toggle_form
        end
        if @last_admin
          p(class: "mt-3 text-xs text-amber-700 dark:text-amber-400") do
            "This is the last tenant administrator. Promote another member before demoting."
          end
        end
      end
    end
  end

  def current_role_summary
    div do
      p(class: "text-sm text-gray-600 dark:text-gray-300 mb-1") { "Current role" }
      if @tenant_user.admin?
        render Components::Kit::Badge.new("Admin", variant: :primary)
      else
        render Components::Kit::Badge.new("Member", variant: :default)
      end
    end
  end

  def role_toggle_form
    target_role = @tenant_user.admin? ? "member" : "admin"
    label = @tenant_user.admin? ? "Demote to member" : "Promote to admin"
    disabled = @tenant_user.admin? && @last_admin

    form_with_url(tenant_user_path(@tenant_user), method: :patch) do
      input(type: "hidden", name: "tenant_user[role]", value: target_role)
      button(
        type: "submit",
        class: button_classes(disabled: disabled),
        disabled: disabled
      ) { label }
    end
  end

  def collaborators_card
    render Components::Kit::Card.new(title: "Framework involvement") do |card|
      card.body do
        if @collaborator_rows.any?
          collaborator_table
        else
          p(class: "text-sm text-gray-600 dark:text-gray-300") do
            "No framework collaborator assignments yet."
          end
        end
        assignment_form_section if @frameworks.any?
      end
    end
  end

  def assignment_form_section
    div(class: "mt-6 pt-6 border-t border-gray-200 dark:border-gray-700") do
      h4(class: "text-sm font-semibold text-gray-900 dark:text-white mb-3") do
        "Add a framework collaborator role"
      end
      render Views::Frameworks::Collaborators::AssignmentForm.new(
        form_url: tenant_user_collaborators_path(@tenant_user),
        scope_picker_url: collaborator_scope_picker_tenant_user_path(@tenant_user),
        framework: nil,
        frameworks: @frameworks,
        people: [],
        person_locked: true
      )
    end
  end

  def collaborator_table
    div(class: "overflow-x-auto") do
      table(class: "min-w-full divide-y divide-gray-200 dark:divide-gray-700") do
        thead(class: "bg-gray-50 dark:bg-gray-900/50") do
          tr do
            th_label "Framework"
            th_label "Role"
            th_label "Scope"
            th_label ""
          end
        end
        tbody(class: "divide-y divide-gray-200 dark:divide-gray-700") do
          @collaborator_rows.each { |row| collaborator_row(row) }
        end
      end
    end
  end

  def collaborator_row(row)
    tr do
      cell { row.framework_name }
      cell { render Components::Kit::Badge.new(row.role.humanize, variant: role_variant(row.role)) }
      cell { row.scope_label }
      cell(extra_classes: "text-right") { remove_collaborator_button(row) }
    end
  end

  def remove_collaborator_button(row)
    form_with_url(
      tenant_user_collaborator_path(@tenant_user, row.destroy_id),
      method: :delete
    ) do
      button(
        type: "submit",
        class: "text-sm text-red-700 dark:text-red-400 hover:underline"
      ) { "Remove" }
    end
  end

  def role_variant(role)
    case role
    when "owner" then :primary
    when "editor" then :info
    when "viewer" then :default
    when "collaborator" then :info
    else :default
    end
  end

  def th_label(text)
    th(class: "px-4 py-3 text-left text-xs font-medium uppercase tracking-wider " \
              "text-gray-600 dark:text-gray-300") { text }
  end

  def cell(extra_classes: nil, &block)
    classes = "px-4 py-3 text-sm text-gray-900 dark:text-gray-100"
    classes = "#{classes} #{extra_classes}" if extra_classes
    td(class: classes, &block)
  end

  def display_name
    @person.name.presence || TenantUser.derive_person_name(@tenant_user.user.email)
  end

  # Phlex-friendly form_with that includes the CSRF token + method spoof.
  def form_with_url(url, method:)
    form(action: url, method: "post", class: "inline-block") do
      input(type: "hidden", name: "_method", value: method.to_s.upcase)
      input(type: "hidden", name: "authenticity_token",
            value: view_context.form_authenticity_token)
      yield
    end
  end

  def button_classes(disabled:)
    base = "inline-flex items-center rounded-md px-3 py-2 text-sm font-medium " \
           "border border-gray-300 dark:border-gray-600 " \
           "bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100"
    base += if disabled
      " opacity-50 cursor-not-allowed"
    else
      " hover:bg-gray-50 dark:hover:bg-gray-700"
    end
    base
  end
end
