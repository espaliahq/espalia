# frozen_string_literal: true

# What the next HRIS sync would do to each HRIS-managed person, and the same
# answer grouped by job title.
#
# The ONE resolution of HRIS title → framework role and level: the sync's
# Pass 5 dispatches on these rows ({Hris::Hibob::Adapter#assign_to_framework}),
# and the integrations page, the MCP read tool and a mapping edit's preview
# read the same rows — so what they describe is what the sync does.
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

  # What one title and level resolve to.
  Target = Data.define(:title, :mapping, :role, :level, :ordinal) do
    # @return [Symbol] why it resolves to nothing, or :resolved
    def status
      return Integrations::HrisPersonRow::STATUS_NO_TITLE if title.blank?
      return Integrations::HrisPersonRow::STATUS_UNMAPPED if mapping.nil?
      return Integrations::HrisPersonRow::STATUS_MISSING_ROLE if role.nil?
      return Integrations::HrisPersonRow::STATUS_MISSING_ORDINAL if ordinal.nil?
      return Integrations::HrisPersonRow::STATUS_MISSING_LEVEL if level.nil?

      :resolved
    end
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

    assignments = PersonFrameworkAssignment.where(person_id: people.map(&:id), framework_id: framework&.framework_id)
      .includes(:role, :level).index_by(&:person_id)

    people.map do |person|
      target = target(person.job_title, person.hris_level_ordinal)
      Integrations::HrisPersonRow.new(
        person: person, mapping: target.mapping, role: target.role, level: target.level, assignment: assignments[person.id]
      )
    end
  end

  # The role and level a title and HRIS level resolve to, through the
  # tenant's mapping. The rows and the Org Graph feed both resolve here.
  #
  # @param title [String, nil]
  # @param hris_level_ordinal [Integer, nil] the HRIS level, used when the mapping fixes none
  # @return [Target]
  def target(title, hris_level_ordinal)
    mapping = title.present? ? title_lookup[HrisRoleMapping.normalize_title(title)] : nil
    role = mapping && roles_by_code[mapping.framework_role_code]
    ordinal = mapping && (mapping.level_ordinal || hris_level_ordinal)
    level = role && ordinal && levels_by_role_and_ordinal[[ role.role_id, ordinal ]]
    Target.new(title:, mapping:, role:, level:, ordinal:)
  end

  # Distinct titles held by active HRIS people, unmapped first, then by title.
  #
  # @return [Array<Title>]
  def titles
    @titles ||= group_titles(rows(active_people.order(:name)))
  end

  # The active HRIS people holding one title, resolved — without resolving
  # everyone else.
  #
  # @param title [String]
  # @return [Title, nil]
  def title(title)
    normalized = HrisRoleMapping.normalize_title(title)
    return nil if normalized.empty?

    # ILIKE narrows in SQL; the exact comparison stays in Ruby so it is the
    # same `normalize_title` the sync matches with.
    candidates = active_people.where("job_title ILIKE ?", "%#{Person.sanitize_sql_like(normalized)}%")
      .select { |person| HrisRoleMapping.normalize_title(person.job_title) == normalized }
    group_titles(rows(candidates)).first
  end

  # The framework role a mapping's code resolves to — the same lookup the
  # sync uses, so a mapping validated here is one the sync can apply.
  #
  # @param code [String]
  # @return [FrameworkState::Role, nil]
  def role_for(code)
    roles_by_code[code]
  end

  # The framework the sync assigns people into.
  #
  # @return [FrameworkState::Framework, nil]
  def framework
    return @framework if defined?(@framework)

    @framework = FrameworkState::Framework.first
  end

  # The framework's roles, for choosing a mapping target.
  #
  # @return [Array<FrameworkState::Role>]
  def roles
    roles_by_code.values.sort_by(&:name)
  end

  # @return [Hash{String => Array<Integer>}] role code → the level ordinals it has
  def level_ordinals_by_role_code
    ordinals_by_role_id = levels_by_role_and_ordinal.keys.group_by(&:first)
      .transform_values { |keys| keys.map(&:last).sort }
    roles_by_code.transform_values { |role| ordinals_by_role_id.fetch(role.role_id, []) }
  end

  private

  def active_people
    Person.hris_managed.where(status: "active").where.not(job_title: [ nil, "" ])
  end

  def group_titles(rows)
    rows.group_by { |row| HrisRoleMapping.normalize_title(row.person.job_title) }
      .map { |_, group| Title.new(title: group.first.person.job_title.strip, mapping: group.first.mapping, rows: group) }
      .sort_by { |entry| [ entry.unmapped? ? 0 : 1, entry.title.downcase ] }
  end

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
