# frozen_string_literal: true

# Lists all career frameworks for the current tenant.
#
# Displays each framework as a card with summary stats
# (role families, capabilities) and a link to the detail view.
#
class Views::Frameworks::IndexView < Views::Base
  # @param frameworks [ActiveRecord::Relation<FrameworkState::Framework>]
  # @param user [User, nil] the currently signed-in user
  # @param current_tenant [Tenant, nil] the active tenant
  # @param tenants [Array<Tenant>] all tenants the user belongs to
  def initialize(frameworks:, user: nil, current_tenant: nil, tenants: [])
    @frameworks = frameworks
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      page_header
      framework_grid
    end
  end

  private

  def page_header
    render Components::Kit::SectionHeading.new(
      "Frameworks",
      subtitle: "#{@frameworks.size} #{'framework'.pluralize(@frameworks.size)}"
    )
  end

  def framework_grid
    if @frameworks.any?
      div(class: "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6") do
        @frameworks.each { |fw| framework_card(fw) }
      end
    else
      empty_state
    end
  end

  def framework_card(framework)
    a(href: framework_path(framework.framework_id),
      class: "block group") do
      render Components::Kit::Card.new do |card|
        card.body do
          h3(class: "text-lg font-semibold text-gray-900 dark:text-white " \
                    "group-hover:text-primary-ink transition-colors") do
            framework.name
          end

          div(class: "mt-4 flex gap-4 text-sm text-gray-600 dark:text-gray-300") do
            stat_pill("Role families", framework.role_families.size)
            stat_pill("Capabilities", framework.capability_categories.sum { |c| c.capabilities.size })
          end

          div(class: "mt-3") do
            render Components::Kit::Badge.new("v#{framework.current_published_version}", variant: :info)
          end
        end
      end
    end
  end

  def stat_pill(label, count)
    span do
      span(class: "font-semibold text-gray-900 dark:text-white") { count.to_s }
      plain " #{label}"
    end
  end

  def empty_state
    div(class: "text-center py-12") do
      p(class: "text-gray-600 dark:text-gray-300") { "No frameworks defined yet." }
    end
  end
end
