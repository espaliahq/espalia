# frozen_string_literal: true

# What the next HRIS sync would do to each HRIS-managed person, and the same
# answer grouped by job title.
#
# Mirrors {Hris::Hibob::Adapter#dispatch_framework_assignment}'s predicates
# without dispatching anything, so the integrations page, the MCP read tool
# and a mapping edit's preview all describe the sync the same way. Keep any
# change to the resolution rules in step with the adapter.
#
# @example
#   resolution = Integrations::HrisTitleResolution.new(tenant)
#   resolution.rows                  # => [Integrations::HrisPersonRow, ...]
#   resolution.titles.select(&:unmapped?)
class Integrations::HrisTitleResolution
  # One job title held by active HRIS people.
  Title = Data.define(:title, :mapping, :rows) do
    # @return [Boolean]
    def unmapped? = mapping.nil?

    # @return [Integer]
    def people_count = rows.size

    # @return [Array<Integer>] the distinct HRIS level-column values its holders carry
    def hris_levels = rows.filter_map { |row| row.person.hris_level_ordinal }.uniq.sort

    # Holders whose assignment the next sync would change, or who keep one
    # an earlier title gave them because this title resolves to nothing.
    #
    # @return [Array<Integrations::HrisPersonRow>]
    def attention_rows = rows.select { |row| row.changes_on_sync? || row.stale_assignment? }
  end

  # @param tenant [Tenant]
  def initialize(tenant)
    @tenant = tenant
  end

  # @param people [Enumerable<Person>, nil] defaults to every HRIS-managed person
  # @return [Array<Integrations::HrisPersonRow>]
  def rows(people = nil)
    people = (people || default_people).to_a
    return [] if people.empty?

    assignments = PersonFrameworkAssignment.where(person_id: people.map(&:id))
      .includes(:role, :level).index_by(&:person_id)

    people.map do |person|
      mapping = person.job_title.present? ? title_lookup[HrisRoleMapping.normalize_title(person.job_title)] : nil
      role = mapping && roles_by_code[mapping.framework_role_code]
      ordinal = mapping && (mapping.level_ordinal || person.hris_level_ordinal)
      level = role && ordinal && levels_by_role_and_ordinal[[ role.role_id, ordinal ]]

      Integrations::HrisPersonRow.new(
        person: person, mapping: mapping, role: role, level: level, assignment: assignments[person.id]
      )
    end
  end

  # Distinct titles held by active HRIS people, unmapped first, then by title.
  #
  # @return [Array<Title>]
  def titles
    active = rows(Person.hris_managed.where(status: "active").where.not(job_title: [ nil, "" ]).order(:name))

    active.group_by { |row| HrisRoleMapping.normalize_title(row.person.job_title) }
      .map { |_, group| Title.new(title: group.first.person.job_title.strip, mapping: group.first.mapping, rows: group) }
      .sort_by { |title| [ title.unmapped? ? 0 : 1, title.title.downcase ] }
  end

  # The framework's roles, for choosing a mapping target.
  #
  # @return [Array<FrameworkState::Role>]
  def roles
    roles_by_code.values.sort_by(&:name)
  end

  # @return [Hash{String => Array<Integer>}] role code → the level ordinals it has
  def level_ordinals_by_role_code
    roles_by_code.transform_values do |role|
      levels_by_role_and_ordinal.keys.filter_map { |role_id, ordinal| ordinal if role_id == role.role_id }.sort
    end
  end

  private

  def default_people
    Person.hris_managed.includes(:manager).order(status: :asc, name: :asc)
  end

  def title_lookup
    @title_lookup ||= @tenant.hris_config.title_lookup
  end

  def roles_by_code
    @roles_by_code ||= FrameworkState::Role.all.index_by(&:code)
  end

  def levels_by_role_and_ordinal
    @levels_by_role_and_ordinal ||= FrameworkState::Level.all.index_by { |level| [ level.role_id, level.ordinal ] }
  end
end
