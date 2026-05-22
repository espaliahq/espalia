# frozen_string_literal: true

# View row for a single FrameworkState::Collaborator on the per-framework
# collaborators screen.
#
# Resolves the person name and a human-readable scope label (e.g.
# "Framework-wide", "Role: Software Engineer") from a single framework
# context — keeps the Phlex view free of lookups.
#
class FrameworkCollaboratorRow
  attr_reader :collaborator, :person_name, :role, :scope_label

  # @param collaborators [Array<FrameworkState::Collaborator>]
  # @param framework [FrameworkState::Framework]
  # @return [Array<FrameworkCollaboratorRow>]
  def self.build_many(collaborators, framework)
    person_ids = collaborators.map(&:person_id).uniq
    person_by_id = Person.where(id: person_ids).index_by(&:id)
    collaborators.map { |c| new(c, framework, person_by_id) }
  end

  def initialize(collaborator, framework, person_by_id)
    @collaborator = collaborator
    @framework = framework
    person = person_by_id[collaborator.person_id]
    @person_name = person&.name.presence || person&.email || "Unknown person"
    @role = collaborator.role
    @scope_label = resolve_scope_label(collaborator)
  end

  # @return [String] composite id for the destroy route
  def destroy_id
    [
      @collaborator.person_id,
      @collaborator.role,
      @collaborator.scope_type,
      @collaborator.scope_id
    ].map(&:to_s).join(":")
  end

  private

  def resolve_scope_label(collaborator)
    return "Framework-wide" if collaborator.scope_type.blank?

    klass, key = TenantUserCollaboratorRow::SCOPE_RESOLVERS[collaborator.scope_type]
    label = TenantUserCollaboratorRow::SCOPE_LABELS[collaborator.scope_type] ||
            collaborator.scope_type.humanize
    return label if klass.nil?

    entity = klass.find_by(key => collaborator.scope_id)
    name = entity&.name
    name.present? ? "#{label}: #{name}" : label
  end
end
