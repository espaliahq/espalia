# frozen_string_literal: true

# Shared page layout composing Navbar and main content area.
#
# On desktop: nav links are in the top Navbar, main content gets full width.
# On mobile: hamburger opens a Sidebar drawer overlay.
#
# @example
#   render Components::Kit::PageLayout.new(user: current_user, current_tenant: tenant, tenants: tenants) do
#     h1 { "Page Title" }
#   end
#
class Components::Kit::PageLayout < Components::Base
  # @param user [User, nil] the currently signed-in user
  # @param current_tenant [Tenant, nil] the active tenant
  # @param tenants [Array<Tenant>] all tenants the user belongs to
  def initialize(user: nil, current_tenant: nil, tenants: [])
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template(&block)
    div(
      class: "min-h-screen flex flex-col bg-gray-50 dark:bg-gray-950",
      data: { controller: "sidebar" }
    ) do
      render Components::Kit::Navbar.new(
        app_name: "GrowthOS",
        links: nav_links,
        user: @user,
        current_tenant: @current_tenant,
        tenants: @tenants
      )

      # Mobile-only sidebar drawer
      render Components::Kit::Sidebar.new(links: nav_links)

      main(class: "flex-1 p-6 overflow-auto", &block)
    end
  end

  private

  # Builds nav links, adjusting the Framework link based on count
  # and conditionally adding an Assessment link for open cycles.
  #
  # @return [Array<Hash>]
  def nav_links
    @nav_links ||= begin
      links = [
        { label: "Home", href: "/" },
        framework_nav_link
      ]
      assessment_link = assessment_nav_link
      links << assessment_link if assessment_link
      links
    end
  end

  def framework_nav_link
    frameworks = FrameworkState::Framework.all
    if frameworks.size == 1
      { label: "Framework", href: "/frameworks/#{frameworks.first.framework_id}" }
    else
      { label: "Frameworks", href: "/frameworks" }
    end
  end

  # Returns an assessment nav link if the current user has an open assessment cycle
  # or has direct reports with framework assignments (manager view).
  # Links directly to the assessment when exactly one own cycle exists and no
  # report assignments, otherwise to the index.
  #
  # @return [Hash, nil]
  def assessment_nav_link
    return unless @user

    person = resolve_person
    return unless person

    assignments = PersonFrameworkAssignment.for_person(person.id).with_open_cycle
    has_report_assignments = person.direct_reports
      .where(id: PersonFrameworkAssignment.select(:person_id))
      .exists?

    if assignments.size == 1 && !has_report_assignments
      { label: "Assessment", href: "/assessments/#{assignments.first.framework_id}" }
    elsif assignments.any? || has_report_assignments
      { label: "Assessments", href: "/assessments" }
    end
  end

  # Resolves the Person for the current user in the current tenant.
  #
  # @return [Person, nil]
  def resolve_person
    return unless @current_tenant

    tenant_user = ActsAsTenant.without_tenant do
      @user.tenant_users.find_by(tenant: @current_tenant)
    end
    tenant_user&.person
  end
end
