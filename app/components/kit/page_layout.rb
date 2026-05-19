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
  # and conditionally adding Assessment / Integrations links based on
  # the current user's role and assignments.
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
      links << { label: "Cycles", href: "/assessment_cycles" } if show_cycles_link?
      links << { label: "Integrations", href: "/integrations" } if show_integrations_link?
      links
    end
  end

  # Whether the current viewer can manage assessment cycles.
  # Visible to global admins and tenant admins only.
  #
  # @return [Boolean]
  def show_cycles_link?
    return false unless @user && @current_tenant
    return true if @user.global_admin?

    resolve_tenant_user&.admin?
  end

  # Whether the current viewer can manage tenant integrations.
  # Visible to global admins and tenant admins only.
  #
  # @return [Boolean]
  def show_integrations_link?
    return false unless @user && @current_tenant
    return true if @user.global_admin?

    resolve_tenant_user&.admin?
  end

  # Resolves the TenantUser membership for the current user/tenant pair.
  # Cached so the navbar doesn't re-query for every link helper.
  #
  # @return [TenantUser, nil]
  def resolve_tenant_user
    return @resolved_tenant_user if defined?(@resolved_tenant_user)

    @resolved_tenant_user = ActsAsTenant.without_tenant do
      @user.tenant_users.find_by(tenant: @current_tenant)
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

    # Assignments for the current person where an AssessmentCycle is open and
    # this person is still an active participant.
    assignments = PersonFrameworkAssignment
      .for_person(person.id)
      .joins("INNER JOIN assessment_cycles ON assessment_cycles.framework_id = " \
             "person_framework_assignments.framework_id AND assessment_cycles.status = 'open'")
      .joins("INNER JOIN assessment_cycle_enrollments " \
             "ON assessment_cycle_enrollments.cycle_id = assessment_cycles.cycle_id " \
             "AND assessment_cycle_enrollments.person_id = person_framework_assignments.person_id " \
             "AND assessment_cycle_enrollments.status <> 'withdrawn'")
      .distinct
    has_report_assignments = person.direct_reports
      .where(id: PersonFrameworkAssignment.select(:person_id))
      .exists?

    if assignments.size == 1 && !has_report_assignments
      { label: "Assessment", href: "/assessments/#{assignments.first.id}" }
    elsif assignments.any? || has_report_assignments
      { label: "Assessments", href: "/assessments" }
    end
  end

  # Resolves the Person for the current user in the current tenant.
  #
  # @return [Person, nil]
  def resolve_person
    resolve_tenant_user&.person
  end
end
