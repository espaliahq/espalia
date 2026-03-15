# frozen_string_literal: true

# Full read-only display of a career framework.
#
# Shows the complete framework structure: role families with roles and levels,
# capability categories with capabilities, behavioural expectations, and
# role-specific illustrations.
#
class Views::Frameworks::ShowView < Views::Base
  # @param framework [FrameworkState::Framework]
  # @param role_families [ActiveRecord::Relation<FrameworkState::RoleFamily>]
  # @param categories [ActiveRecord::Relation<FrameworkState::CapabilityCategory>]
  # @param user [User, nil] the currently signed-in user
  # @param current_tenant [Tenant, nil] the active tenant
  # @param tenants [Array<Tenant>] all tenants the user belongs to
  def initialize(framework:, role_families:, categories:, user: nil, current_tenant: nil, tenants: [])
    @framework = framework
    @role_families = role_families
    @categories = categories
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      framework_header
      stats_section
      nav_tabs
      roles_section
      capabilities_section
    end
  end

  private

  # ── Header ──

  def framework_header
    div(class: "mb-6") do
      a(href: frameworks_path,
        class: "text-sm text-gray-500 dark:text-gray-400 hover:text-primary mb-2 inline-block") do
        plain "← Frameworks"
      end
      div(class: "flex items-center gap-3") do
        h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { @framework.name }
        render Components::Kit::Badge.new("v#{@framework.current_published_version}", variant: :info)
      end
    end
  end

  def stats_section
    role_count = @role_families.sum { |rf| rf.roles.size }
    level_count = @role_families.sum { |rf| rf.roles.sum { |r| r.levels.size } }
    cap_count = @categories.sum { |c| c.capabilities.size }
    exp_count = @categories.sum { |c| c.capabilities.sum { |cap| cap.expectations.size } }

    div(class: "mb-8") do
      render Components::Kit::DescriptionList.new(
        columns: 4,
        items: [
          { term: "Roles", detail: role_count.to_s },
          { term: "Levels", detail: level_count.to_s },
          { term: "Capabilities", detail: cap_count.to_s },
          { term: "Expectations", detail: exp_count.to_s }
        ]
      )
    end
  end

  # ── Nav Tabs ──

  def nav_tabs
    nav(class: "flex gap-1 border-b border-gray-200 dark:border-gray-700 mb-8") do
      tab_link("Roles & Levels", "#roles", active: true)
      tab_link("Capabilities", "#capabilities")
    end
  end

  def tab_link(label, href, active: false)
    base = "px-4 py-2.5 text-sm font-medium border-b-2 -mb-px transition-colors"
    classes = if active
      "#{base} border-primary text-primary"
    else
      "#{base} border-transparent text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-300"
    end
    a(href: href, class: classes) { label }
  end

  # ── Roles & Levels ──

  def roles_section
    div(id: "roles", class: "mb-12") do
      render Components::Kit::SectionHeading.new(
        "Roles & Levels",
        subtitle: "#{@role_families.size} #{'family'.pluralize(@role_families.size)}"
      )

      div(class: "space-y-6") do
        @role_families.each { |rf| role_family_card(rf) }
      end
    end
  end

  def role_family_card(role_family)
    render Components::Kit::Card.new(title: role_family.name, variant: :flush) do |card|
      card.body do
        table(class: "w-full") do
          thead do
            tr(class: "border-b border-gray-100 dark:border-gray-700") do
              th(class: "text-left px-6 py-3 text-xs font-medium text-gray-500 dark:text-gray-400 uppercase") { "Role" }
              th(class: "text-left px-6 py-3 text-xs font-medium text-gray-500 dark:text-gray-400 uppercase") { "Track" }
              th(class: "text-left px-6 py-3 text-xs font-medium text-gray-500 dark:text-gray-400 uppercase") { "Levels" }
            end
          end
          tbody do
            role_family.roles.sort_by(&:name).each { |role| role_row(role) }
          end
        end
      end
    end
  end

  def role_row(role)
    tr(class: "border-b border-gray-50 dark:border-gray-800 last:border-0") do
      td(class: "px-6 py-4") do
        span(class: "font-medium text-gray-900 dark:text-white") { role.name }
        span(class: "ml-2 text-gray-400 text-sm") { "(#{role.code})" }
      end
      td(class: "px-6 py-4") do
        variant = role.track == "management" ? :warning : :info
        render Components::Kit::Badge.new(role.track.upcase, variant: variant)
      end
      td(class: "px-6 py-4") do
        level_badges(role)
      end
    end
  end

  def level_badges(role)
    div(class: "flex flex-wrap gap-1.5") do
      role.levels.sort_by(&:ordinal).each do |level|
        span(class: "inline-flex items-center rounded-md bg-gray-100 dark:bg-gray-700 " \
                    "px-2 py-1 text-xs font-medium text-gray-600 dark:text-gray-300",
             title: level.title) do
          level.code
        end
      end
    end
  end

  # ── Capabilities ──

  def capabilities_section
    div(id: "capabilities", class: "mb-12") do
      render Components::Kit::SectionHeading.new(
        "Capabilities",
        subtitle: "#{@categories.size} #{'category'.pluralize(@categories.size)}"
      )

      div(class: "space-y-10") do
        @categories.each { |cat| category_section(cat) }
      end
    end
  end

  def category_section(category)
    div do
      render Components::Kit::SectionHeading.new(
        category.name,
        subtitle: category.description,
        tag: :h3
      )

      div(class: "space-y-4") do
        category.capabilities.sort_by(&:name).each { |cap| capability_card(cap) }
      end
    end
  end

  def capability_card(capability)
    render Components::Kit::Card.new do |card|
      card.body do
        capability_header(capability)
        capability_bindings(capability) if capability.bindings.any?
        capability_expectations(capability) if capability.expectations.any?
      end
    end
  end

  def capability_header(capability)
    div(class: "flex items-start justify-between mb-4") do
      div do
        h4(class: "text-base font-semibold text-gray-900 dark:text-white") { capability.name }
        p(class: "mt-1 text-sm text-gray-600 dark:text-gray-400") { capability.description } if capability.description.present?
      end
      render Components::Kit::Badge.new(capability.status.capitalize, variant: capability.status == "active" ? :success : :default)
    end
  end

  def capability_bindings(capability)
    div(class: "mb-4") do
      p(class: "text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-2") { "Bound to" }
      div(class: "flex flex-wrap gap-1.5") do
        capability.bindings.each do |binding|
          role = FrameworkState::Role.find_by(role_id: binding.role_id)
          next unless role

          render Components::Kit::Badge.new(role.code, variant: :default)
        end
      end
    end
  end

  def capability_expectations(capability)
    div do
      p(class: "text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-3") { "Expectations by level" }
      div(class: "space-y-3") do
        capability.expectations.sort_by(&:level_ordinal).each { |exp| expectation_row(exp) }
      end
    end
  end

  def expectation_row(expectation)
    div(class: "border-l-2 border-gray-200 dark:border-gray-700 pl-4") do
      div(class: "flex items-baseline gap-2 mb-1") do
        span(class: "inline-flex items-center justify-center w-6 h-6 rounded-full " \
                    "bg-primary/10 text-primary text-xs font-bold") do
          expectation.level_ordinal.to_s
        end
        p(class: "text-sm text-gray-900 dark:text-white") { expectation.description }
      end

      illustrations_list(expectation) if expectation.illustrations.any?
    end
  end

  def illustrations_list(expectation)
    div(class: "ml-8 mt-2 space-y-1.5") do
      expectation.illustrations.sort_by(&:ordinal).each do |ill|
        role = FrameworkState::Role.find_by(role_id: ill.role_id)
        div(class: "flex items-start gap-2 text-sm") do
          if role
            span(class: "shrink-0 text-xs font-mono font-medium text-gray-400 dark:text-gray-500 " \
                        "bg-gray-100 dark:bg-gray-800 rounded px-1.5 py-0.5 mt-0.5") do
              role.code
            end
          end
          span(class: "text-gray-600 dark:text-gray-400") { ill.description }
        end
      end
    end
  end
end
