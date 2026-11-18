# frozen_string_literal: true

# The caller's team as one set of capabilities: the payload the assessments
# page's team card and team map render, so the web and an agent read one set
# of numbers. A manager can open everyone below them, so the aggregate shows
# nothing they can't already see and needs no minimum group size.
class Operations::Assessments::TeamCapabilities < Operations::Base
  PERSPECTIVES = { "manager" => :manager_only, "self" => :self_only, "aligned" => :aligned_only }.freeze

  description "The caller's team as one set of capabilities, one role at a time: each capability's score is the " \
              "mean of everyone's score on it against their own level, as a percentage (100 is the team meeting " \
              "it on average), with how many were scored and how many are short. gaps lists capabilities where " \
              "more than half are short. people is direct (direct reports, the default) or below (everyone " \
              "below the caller); ratings is manager (the default), self or aligned. Only people whose score has " \
              "unlocked count. compare is level (the default) or none: with level, each capability's " \
              "group_median is everyone on the role at the team's levels, team included, from the level " \
              "comparison's monthly snapshot of agreed ratings, weighted by how many of the team are at each " \
              "level; comparison says when it was taken, or why there is no line (off, no_snapshot, or too_few " \
              "with the short_levels under min_group_size). Nothing names anyone on the team."
  category :read
  approval :none

  parameter :people, String, allowed: %w[direct below]
  parameter :ratings, String, allowed: PERSPECTIVES.keys
  parameter :role_id, String
  parameter :level_ordinal, Integer
  parameter :compare, String, allowed: %w[level none]

  # @raise [Pundit::NotAuthorizedError] unless the caller is a person
  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize PersonFrameworkAssignment, :index?
  end

  # @return [Hash]
  def perform
    { people:, indirect_reports: indirect_reports?, ratings:, role: result.role && { id: result.role.role_id, name: result.role.name },
      roles: result.roles.map { |r| { id: r.role_id, name: r.name, people: r.people } },
      level_ordinal: result.level_ordinal, levels: result.levels.map(&:to_h),
      in_view: result.people, scored: result.scored, met: result.met, comparison: comparison_payload,
      capabilities: result.capabilities.map { |c| capability(c) },
      gaps: result.gaps.map { |c| { stable_id: c.stable_id, name: c.name, short: c.short, scored: c.scored } } }
  end

  private

  def people = params[:people] || "direct"

  # Nil when compared with nothing, or when the team has no role in view.
  def comparison
    return @comparison if defined?(@comparison)

    @comparison = if params[:compare] != "none" && result.role
      Assessments::TeamComparison.new(tenant: ActsAsTenant.current_tenant, role_id: result.role.role_id,
                                      level_counts: level_counts).call
    end
  end

  def level_counts
    levels = result.levels.select { |level| result.level_ordinal.nil? || level.ordinal == result.level_ordinal }
    levels.to_h { |level| [ level.ordinal, level.people ] }
  end

  def comparison_payload
    return { shown: false, reason: "none" } unless comparison

    codes = result.levels.to_h { |level| [ level.ordinal, level.code ] }
    { shown: comparison.shown?, reason: comparison.reason&.to_s, taken_on: comparison.taken_on&.iso8601,
      min_group_size: comparison.min_group_size, group_size: comparison.group_size,
      short_levels: comparison.short_ordinals.map { |ordinal| codes[ordinal] } }
  end

  def ratings = params[:ratings] || "manager"

  def result
    @result ||= Assessments::TeamCapabilities.new(
      person_ids: people == "below" ? context.person.all_reports.pluck(:id) : direct_report_ids,
      perspective: PERSPECTIVES.fetch(ratings), role_id: params[:role_id], level_ordinal: params[:level_ordinal]
    ).call
  end

  def direct_report_ids = @direct_report_ids ||= context.person.direct_reports.pluck(:id)

  def indirect_reports? = context.person.all_reports.where.not(id: direct_report_ids).exists?

  def capability(capability)
    { stable_id: capability.stable_id, name: capability.name, category_id: capability.category_id,
      category_name: capability.category_name, hue: capability.hue,
      score: percent(capability.score), scored: capability.scored, short: capability.short,
      group_median: percent(comparison&.medians&.[](capability.stable_id)) }
  end

  # A score short of met never reads as 100, so the number agrees with the dashed circle.
  def percent(score)
    return unless score

    score < 1.0 ? [ (score * 100).round, 99 ].min : (score * 100).round
  end
end
