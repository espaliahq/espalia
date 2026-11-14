# frozen_string_literal: true

# Constructs tenant-namespaced RailsEventStore stream names.
#
# All event streams include the tenant ID as a prefix to ensure
# tenant isolation within the shared event store tables. Stream names
# MUST always be constructed via this module — never built by hand.
#
# @example
#   EventStreamNaming.framework_stream("fw-uuid-123")
#   # => "tenant-<tenant-uuid>/Framework-fw-uuid-123"
#
#   EventStreamNaming.person_development_stream("person-uuid", "fw-uuid")
#   # => "tenant-<tenant-uuid>/PersonDev-person-uuid-fw-uuid"
#
#   EventStreamNaming.assessment_cycle_stream("cycle-uuid")
#   # => "tenant-<tenant-uuid>/AssessmentCycle-cycle-uuid"
#
#   EventStreamNaming.org_structure_stream
#   # => "tenant-<tenant-uuid>/OrgStructure"
#
#   EventStreamNaming.plan_stream("plan-uuid")
#   # => "tenant-<tenant-uuid>/Plan-plan-uuid"
#
module EventStreamNaming
  # Returns the stream name for a Framework aggregate.
  #
  # @param framework_id [String] the framework's UUID
  # @param tenant [Tenant, nil] override tenant (defaults to ActsAsTenant.current_tenant)
  # @return [String] the tenant-namespaced stream name
  # @raise [ArgumentError] if no tenant context is available
  def self.framework_stream(framework_id, tenant: ActsAsTenant.current_tenant)
    "#{tenant_prefix(tenant)}/Framework-#{framework_id}"
  end

  # Returns the stream name for a PersonDevelopment aggregate.
  #
  # @param person_id [String] the person's UUID
  # @param framework_id [String] the framework's UUID
  # @param tenant [Tenant, nil] override tenant (defaults to ActsAsTenant.current_tenant)
  # @return [String] the tenant-namespaced stream name
  # @raise [ArgumentError] if no tenant context is available
  def self.person_development_stream(person_id, framework_id, tenant: ActsAsTenant.current_tenant)
    "#{tenant_prefix(tenant)}/PersonDev-#{person_id}-#{framework_id}"
  end

  # Returns the stream name for an AssessmentCycle aggregate.
  #
  # @param cycle_id [String] the cycle's UUID
  # @param tenant [Tenant, nil] override tenant (defaults to ActsAsTenant.current_tenant)
  # @return [String] the tenant-namespaced stream name
  # @raise [ArgumentError] if no tenant context is available
  def self.assessment_cycle_stream(cycle_id, tenant: ActsAsTenant.current_tenant)
    "#{tenant_prefix(tenant)}/AssessmentCycle-#{cycle_id}"
  end

  # Returns the stream name for a CalibrationSession aggregate.
  #
  # @param session_id [String] the calibration session's UUID
  # @param tenant [Tenant, nil] override tenant (defaults to ActsAsTenant.current_tenant)
  # @return [String] the tenant-namespaced stream name
  # @raise [ArgumentError] if no tenant context is available
  def self.calibration_session_stream(session_id, tenant: ActsAsTenant.current_tenant)
    "#{tenant_prefix(tenant)}/CalibrationSession-#{session_id}"
  end

  # Returns the stream name for an Org Graph person: one stream per person,
  # holding the operational facts the Org Graph knows about them.
  #
  # @param person_id [String] the person's UUID
  # @param tenant [Tenant, nil] override tenant (defaults to ActsAsTenant.current_tenant)
  # @return [String] the tenant-namespaced stream name
  # @raise [ArgumentError] if no tenant context is available
  def self.person_stream(person_id, tenant: ActsAsTenant.current_tenant)
    "#{tenant_prefix(tenant)}/Person-#{person_id}"
  end

  # Returns the stream name for a tenant's Org Graph structure: one stream per
  # tenant, holding its taxonomy and every unit's life.
  #
  # @param tenant [Tenant, nil] override tenant (defaults to ActsAsTenant.current_tenant)
  # @return [String] the tenant-namespaced stream name
  # @raise [ArgumentError] if no tenant context is available
  def self.org_structure_stream(tenant: ActsAsTenant.current_tenant)
    "#{tenant_prefix(tenant)}/OrgStructure"
  end

  # Returns the stream name for a Team Planning plan: one stream per plan,
  # holding its scenarios and every change made in them.
  #
  # @param plan_id [String] the plan's UUID
  # @param tenant [Tenant, nil] override tenant (defaults to ActsAsTenant.current_tenant)
  # @return [String] the tenant-namespaced stream name
  # @raise [ArgumentError] if no tenant context is available
  def self.plan_stream(plan_id, tenant: ActsAsTenant.current_tenant)
    "#{tenant_prefix(tenant)}/Plan-#{plan_id}"
  end

  # Extracts the tenant ID from a stream name.
  #
  # @param stream_name [String] a tenant-namespaced stream name
  # @return [String] the tenant UUID
  # @raise [ArgumentError] if the stream name doesn't match the expected format
  def self.extract_tenant_id(stream_name)
    match = stream_name.match(%r{\Atenant-([^/]+)/})
    raise ArgumentError, "Invalid stream name format: #{stream_name}" unless match

    match[1]
  end

  # @api private
  def self.tenant_prefix(tenant)
    raise ArgumentError, "No tenant context available. Set ActsAsTenant.current_tenant or pass tenant: explicitly." unless tenant

    "tenant-#{tenant.id}"
  end
  private_class_method :tenant_prefix
end
