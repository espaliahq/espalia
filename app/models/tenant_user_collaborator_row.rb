# frozen_string_literal: true

# View row for a single FrameworkState::Collaborator on the tenant user
# detail screen.
#
# Resolves the framework name and a human-readable scope label
# ("Framework-wide", "Role: Software Engineer", etc.) from the
# eager-loaded framework state — keeps the Phlex view free of lookups.
#
class TenantUserCollaboratorRow
  SCOPE_RESOLVERS = {
    "role_family"        => [ FrameworkState::RoleFamily, :role_family_id ],
    "role"               => [ FrameworkState::Role, :role_id ],
    "capability_category" => [ FrameworkState::CapabilityCategory, :category_id ],
    "capability"         => [ FrameworkState::Capability, :capability_id ]
  }.freeze

  SCOPE_LABELS = {
    "role_family"        => "Role family",
    "role"               => "Role",
    "capability_category" => "Capability category",
    "capability"         => "Capability"
  }.freeze

  attr_reader :collaborator, :framework_name, :role, :scope_label

  # Builds one row per collaborator, resolving names from the supplied
  # frameworks list (avoids per-row queries).
  #
  # @param collaborators [Array<FrameworkState::Collaborator>]
  # @param frameworks [Array<FrameworkState::Framework>]
  # @return [Array<TenantUserCollaboratorRow>]
  def self.build_many(collaborators, frameworks)
    framework_by_id = frameworks.index_by(&:framework_id)
    collaborators.map { |c| new(c, framework_by_id) }
  end

  def initialize(collaborator, framework_by_id)
    @collaborator = collaborator
    @framework_name = framework_by_id[collaborator.framework_id]&.name || "Unknown framework"
    @role = collaborator.role
    @scope_label = resolve_scope_label(collaborator)
  end

  # @return [String] composite id for the destroy route
  def destroy_id
    [
      @collaborator.framework_id,
      @collaborator.role,
      @collaborator.scope_type,
      @collaborator.scope_id
    ].map(&:to_s).join(":")
  end

  private

  def resolve_scope_label(collaborator)
    return "Framework-wide" if collaborator.scope_type.blank?

    klass, key = SCOPE_RESOLVERS[collaborator.scope_type]
    label = SCOPE_LABELS[collaborator.scope_type] || collaborator.scope_type.humanize
    return label if klass.nil?

    entity = klass.find_by(key => collaborator.scope_id)
    name = entity&.name
    name.present? ? "#{label}: #{name}" : label
  end
end
