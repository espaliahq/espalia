# frozen_string_literal: true

# The open declared explorations (ADR-22) on a set of assessments — what the
# list shows as its Explorations section and as "Exploring PM3" on team
# cards. Never a cohort reader: it reads one person's intent at a time.
#
# With `progress_for:` it also counts, for those assessments, how many of the
# target level's capabilities the person has rated in their open cycle —
# "4 of 10 rated". Without an open cycle there is nothing to count against.
#
# @example
#   Assessments::OpenExplorations.for(assignments, progress_for: own)
#   # => { assignment_id => [#<Entry code="PM3" rated=4 total=10 …>] }
class Assessments::OpenExplorations
  # `rated` is nil when not counted, or when there is no open cycle.
  Entry = Data.define(:exploration, :assignment, :rated, :total) do
    # @return [String, nil] e.g. "PM3"
    def code = exploration.code

    # @return [String, nil] e.g. "Product Manager · PM3"
    def label = exploration.label

    # @return [Hash] the params that read the assessment against the target
    def lens_params = { as_role: exploration.target_role_id, as_level: exploration.target_level_ordinal }
  end

  # @param assignments [Enumerable<PersonFrameworkAssignment>]
  # @param progress_for [Enumerable<PersonFrameworkAssignment>] the ones to
  #   count ratings for
  # @return [Hash{String => Array<Entry>}] keyed by assignment id, oldest first
  def self.for(assignments, progress_for: [])
    new(assignments.to_a, progress_for.to_a).call
  end

  def initialize(assignments, progress_for)
    @assignments = assignments
    @progress_ids = progress_for.to_set(&:id)
  end

  # @return [Hash{String => Array<Entry>}]
  def call
    return {} if @assignments.empty?

    by_key = @assignments.index_by { |a| [ a.person_id, a.framework_id ] }
    explorations = AssessmentExploration.open
      .where(person_id: by_key.keys.map(&:first).uniq, framework_id: by_key.keys.map(&:last).uniq)
      .includes(:target_role, :started_by).order(:started_at).to_a

    explorations.each_with_object(Hash.new { |h, k| h[k] = [] }) do |exploration, out|
      assignment = by_key[[ exploration.person_id, exploration.framework_id ]]
      next unless assignment && exploration.target_role

      rated, total = @progress_ids.include?(assignment.id) ? progress(exploration, assignment) : [ nil, nil ]
      out[assignment.id] << Entry.new(exploration: exploration, assignment: assignment, rated: rated, total: total)
    end
  end

  private

  # @return [Array(Integer, Integer), Array(nil, Integer)] rated and total
  #   capabilities at the target level; rated is nil without an open cycle
  def progress(exploration, assignment)
    scope = Assessments::RoleScope.for(role_id: exploration.target_role_id, framework_id: assignment.framework_id)
      .at_level(exploration.target_level_ordinal)
    total = scope.capability_stable_ids.size
    cycle = assignment.current_open_cycle
    return [ nil, total ] if cycle.nil? || scope.empty?

    rated = AssessmentLevelRating
      .where(cycle_id: cycle.cycle_id, person_id: assignment.person_id, framework_id: assignment.framework_id)
      .within(scope)
      .where.not(self_rated_frequency: nil)
      .distinct.count(:capability_stable_id)
    [ rated, total ]
  end
end
