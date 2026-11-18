# frozen_string_literal: true

# What a person's comparison with their level can show, from the tenant's
# latest snapshot: their level and one either side on the role the page
# reads, each sized once its group meets the tenant's minimum, and the
# group's middle scores only then. A smaller group shows no number at all,
# not even its size, so no comparison can point at one person.
class Assessments::LevelComparison
  Level = Data.define(:ordinal, :code, :own, :group_size, :available)

  # @param lens [Assessments::Lens] the role and level the page reads
  # @param tenant [Tenant]
  def initialize(lens:, tenant:)
    @lens = lens
    @tenant = tenant
  end

  # @return [Boolean] whether the tenant lets people compare at all
  def enabled? = config.enabled

  # @return [Integer]
  def min_group_size = config.min_group_size

  # @return [Date, nil] when the group scores were taken; nil before the first snapshot
  def taken_on = snapshot&.taken_on

  # @return [Integer] the level the page reads
  def own_ordinal = @lens.level.ordinal

  # @return [Array<Level>] the person's level and its neighbours on the ladder, lowest first
  def levels
    @levels ||= neighbours.map do |level|
      size = groups[level.ordinal]&.group_size
      available = size.to_i >= min_group_size
      Level.new(ordinal: level.ordinal, code: level.code, own: level.ordinal == own_ordinal,
                group_size: (size if available), available:)
    end
  end

  # @param ordinal [Integer]
  # @return [LevelComparisonGroup, nil] nil unless the level is offered and its group meets the minimum
  def group_at(ordinal)
    groups[ordinal] if levels.any? { |level| level.ordinal == ordinal && level.available }
  end

  # @return [Integer, nil] the nearest other level with enough people, below first on a tie
  def suggested_ordinal
    levels.reject(&:own).select(&:available).min_by { |level| [ (level.ordinal - own_ordinal).abs, level.ordinal ] }&.ordinal
  end

  private

  def config = @tenant.comparison_config

  def neighbours
    ladder = @lens.role.levels.sort_by(&:ordinal)
    at = ladder.index { |level| level.ordinal == own_ordinal }
    ladder[[ at - 1, 0 ].max..at + 1]
  end

  def snapshot
    return @snapshot if defined?(@snapshot)

    @snapshot = ActsAsTenant.with_tenant(@tenant) { LevelComparisonSnapshot.latest }
  end

  def groups
    @groups ||= if snapshot
      snapshot.groups.where(role_id: @lens.role.role_id).index_by(&:level_ordinal)
    else
      {}
    end
  end
end
