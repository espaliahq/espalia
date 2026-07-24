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
  extend Phlex::Rails::HelperMacros

  # Reads the effective TenantUser for the request — the impersonated target
  # while a tenant admin is "viewing as" another user, otherwise the real
  # admin's own membership (see {Impersonatable}). Role-dependent nav links
  # gate on this so an admin impersonating a member sees the member's menu,
  # not their own admin links. The user menu still shows the real admin
  # (`@user`), who owns the session, tenant switcher, and sign-out.
  register_value_helper :current_tenant_user

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
      # Skip link — first focusable element, visible only on keyboard focus
      # (WCAG 2.4.1 Bypass Blocks). Jumps past the navbar to main content.
      a(
        href: "#main-content",
        class: "sr-only focus:not-sr-only focus:absolute focus:z-50 focus:top-3 focus:left-3 " \
               "focus:rounded-md focus:bg-white focus:dark:bg-gray-900 focus:px-4 focus:py-2 " \
               "focus:text-sm focus:font-medium focus:text-gray-900 focus:dark:text-white " \
               "focus:shadow-lg focus:ring-2 focus:ring-blue-600"
      ) { "Skip to main content" }

      render Components::Kit::Navbar.new(
        app_name: "GrowthOS",
        links: nav_links,
        user: @user,
        current_tenant: @current_tenant,
        tenants: @tenants
      )

      # Mobile-only sidebar drawer
      render Components::Kit::Sidebar.new(links: nav_links)

      main(id: "main-content", tabindex: "-1", class: "flex-1 p-6 focus:outline-hidden", &block)
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
      links << { label: "Feedback / Evidence", href: "/evidence" } if show_evidence_link?
      links << { label: "Calibration", href: "/calibration_sessions" } if show_calibration_link?
      links << { label: "Cycles", href: "/assessment_cycles" } if show_cycles_link?
      links << { label: "Admin", href: "/tenant" } if show_admin_link?
      links
    end
  end

  # Whether to show the evidence-request hub link — anyone linked to a Person
  # can be asked for (or ask for) evidence.
  #
  # @return [Boolean]
  def show_evidence_link?
    resolve_tenant_user&.person_id.present?
  end

  # Whether the current viewer can manage assessment cycles.
  # Visible to global admins and tenant admins only — evaluated against the
  # effective identity, so an admin impersonating a member does not see it.
  #
  # @return [Boolean]
  def show_cycles_link?
    viewer_is_admin?
  end

  # Whether the current viewer can run calibration sessions — admins, or a
  # manager of managers (someone in their subtree has reports of their own).
  # Mirrors CalibrationSessionPolicy#index?.
  #
  # @return [Boolean]
  def show_calibration_link?
    return true if viewer_is_admin?

    person = resolve_tenant_user&.person
    return false unless person

    Person.where(manager_id: person.all_reports.select(:id)).exists?
  end

  # Whether the current viewer can reach the tenant administration
  # hub (theme, users, integrations). Visible to global admins and
  # tenant admins only — evaluated against the effective identity.
  #
  # @return [Boolean]
  def show_admin_link?
    viewer_is_admin?
  end

  # Whether the effective viewer holds admin rights in the active tenant.
  # Reads from {#current_tenant_user} (the impersonated target while "viewing
  # as", otherwise the real admin) so admin-only links disappear during
  # impersonation of a non-admin.
  #
  # @return [Boolean]
  def viewer_is_admin?
    return false unless @current_tenant

    tenant_user = resolve_tenant_user
    return false unless tenant_user

    tenant_user.user&.global_admin? || tenant_user.admin?
  end

  # The effective TenantUser membership the navbar should render for.
  # Cached so the navbar doesn't re-query for every link helper.
  #
  # @return [TenantUser, nil]
  def resolve_tenant_user
    return @resolved_tenant_user if defined?(@resolved_tenant_user)

    @resolved_tenant_user = current_tenant_user
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
