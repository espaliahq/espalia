# frozen_string_literal: true

# What the team map compares a team with: everyone on its role at the team's
# levels, team included, from the tenant's latest level comparison snapshot.
# Each level's median counts as often as the team has people at it, so the
# line matches the team's level mix. It uses the level comparison's group,
# agreed ratings, minimum and snapshot, and shows only when every level in
# view meets that minimum, so no line can point at one person.
class Assessments::TeamComparison
  # `reason` is nil when shown, else :off, :no_snapshot or :too_few;
  # `medians` are stable_id => score, 1.0 the level met.
  Result = Data.define(:reason, :taken_on, :min_group_size, :group_size, :short_ordinals, :medians) do
    # @return [Boolean]
    def shown? = reason.nil?
  end

  # @param tenant [Tenant]
  # @param role_id [String]
  # @param level_counts [Hash{Integer => Integer}] the team's people in view at each level
  def initialize(tenant:, role_id:, level_counts:)
    @tenant = tenant
    @role_id = role_id
    @level_counts = level_counts.select { |_, count| count.positive? }
  end

  # @return [Result]
  def call
    return refused(:off) unless config.enabled
    return refused(:no_snapshot) unless snapshot

    short = @level_counts.keys.select { |level| groups[level].nil? || groups[level].group_size < config.min_group_size }.sort
    return refused(:too_few, short_ordinals: short) if short.any? || @level_counts.empty?

    Result.new(reason: nil, taken_on: snapshot.taken_on, min_group_size: config.min_group_size,
               group_size: @level_counts.keys.sum { |level| groups[level].group_size }, short_ordinals: [],
               medians: weighted_medians)
  end

  private

  def config = @tenant.comparison_config

  def refused(reason, short_ordinals: [])
    Result.new(reason:, taken_on: snapshot&.taken_on, min_group_size: config.min_group_size, group_size: nil,
               short_ordinals:, medians: {})
  end

  def snapshot
    return @snapshot if defined?(@snapshot)

    @snapshot = ActsAsTenant.with_tenant(@tenant) { LevelComparisonSnapshot.latest }
  end

  def groups
    @groups ||= ActsAsTenant.with_tenant(@tenant) do
      snapshot.groups.where(role_id: @role_id, level_ordinal: @level_counts.keys).index_by(&:level_ordinal)
    end
  end

  # A capability some level's snapshot predates is weighted over the levels that have it.
  def weighted_medians
    pairs = @level_counts.flat_map do |level, count|
      groups[level].capability_medians.map { |stable_id, median| [ stable_id, median, count ] }
    end
    pairs.group_by(&:first).transform_values do |rows|
      (rows.sum { |_, median, count| median * count } / rows.sum(&:last).to_f).round(4)
    end
  end
end
