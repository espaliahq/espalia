# frozen_string_literal: true

# A person's scores beside the middle scores of everyone on their role at a
# level. The capability map's comparison tab renders this payload, so the web
# and an agent read one set of numbers.
class Operations::Assessments::LevelComparison < Operations::Base
  description "Compare a person's capabilities with everyone on their role at their level, or one level either " \
              "side: the person's live score on each capability and category beside the group's middle " \
              "(median) score, both as percentages of the compared level (100 is meeting it). Group scores come " \
              "from agreed ratings in a monthly snapshot (taken_on), and show only when the level has at least " \
              "min_group_size people; levels lists each one's size, or nil when too small. Nothing names anyone " \
              "in the group. Returns { enabled: false } when the tenant has comparisons off."
  category :read
  approval :none

  parameter :assignment_id, String, required: true, allow_blank: false
  parameter :level_ordinal, Integer

  # @raise [Pundit::NotAuthorizedError] unless the caller can see the assessment's scores
  def policy_check
    authorize assignment, :scoring?
  end

  # @return [Hash]
  # @raise [ParameterError] for a level that isn't the person's or one either side
  def perform
    return { enabled: false } unless comparison.enabled?

    level = comparison.levels.find { |l| l.ordinal == (params[:level_ordinal] || comparison.own_ordinal) } ||
      raise(ParameterError, "level_ordinal must be #{comparison.levels.map(&:code).to_sentence(last_word_connector: ' or ')}")
    group = comparison.group_at(level.ordinal)
    { enabled: true, taken_on: comparison.taken_on&.iso8601, min_group_size: comparison.min_group_size,
      role: { id: home_lens.role.role_id, name: home_lens.role.name },
      level: { ordinal: level.ordinal, code: level.code, group_size: level.group_size },
      levels: comparison.levels.map(&:to_h), suggested_ordinal: comparison.suggested_ordinal,
      categories: group ? categories(group, level) : [], capabilities: group ? capabilities(group, level) : [] }
  rescue Assessments::Lens::NotFound => e
    raise ParameterError, e.message
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  def home_lens
    @home_lens ||= Assessments::Lens.resolve(assignment:)
  rescue ActiveRecord::RecordNotFound
    raise ParameterError, "This assessment's role or level is no longer in the framework"
  end

  def comparison
    @comparison ||= Assessments::LevelComparison.new(lens: home_lens, tenant: ActsAsTenant.current_tenant)
  end

  def summary(level)
    @summaries ||= {}
    @summaries[level.ordinal] ||= begin
      lens = Assessments::Lens.resolve(assignment:, as_level: level.ordinal)
      Assessments::ScoreSummary.new(
        assignment:, lens:, context: Assessments::ViewerContext.for(assignment:, authorization: context, lens:)
      )
    end
  end

  def categories(group, level)
    summary(level).overall[:categories].filter_map do |category|
      median = group.category_medians[category[:id]]
      next unless median

      { id: category[:id], name: category[:name], scored: category[:scored], your_score: category[:score],
        group_median: percent(median) }
    end
  end

  def capabilities(group, level)
    scores = summary(level)
    home_lens.scope.bindings.filter_map do |binding|
      median = group.capability_medians[binding.capability.stable_id]
      next unless median

      mine = scores.capability(binding.capability.stable_id)
      { stable_id: binding.capability.stable_id, name: binding.capability.name, category_id: binding.capability.category_id,
        scored: mine&.fetch(:scored) || false, your_score: mine&.fetch(:score), group_median: percent(median) }
    end
  end

  def percent(score) = (score * 100).round
end
