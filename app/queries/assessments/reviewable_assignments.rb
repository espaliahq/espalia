# frozen_string_literal: true

# The framework assignments a person reviews, split the way the Assessments
# index (and the MCP assessments_mine tool) present them:
#
# - {#team} — assignments the person actively rates: their direct reports'
#   plus any assignment they hold an active manager-rating delegation for
#   (e.g. a report seconded into their team).
# - {#skip_level} — view-only assignments for everyone deeper in their org
#   subtree (all reports minus direct reports), excluding anything already
#   surfaced in {#team} so an assignment never appears twice.
#
# Single source of truth for both the web controller and the MCP operation.
# The two used to carry near-identical private copies of this logic and
# drifted immediately (delegated skip-level assignments leaked into the MCP
# skip-level list while the web index filed them under Team) — keep any
# future change to this split HERE, not in a caller.
class Assessments::ReviewableAssignments
  # @param person [Person]
  def initialize(person)
    @person = person
  end

  # @return [ActiveRecord::Relation<PersonFrameworkAssignment>]
  def team
    @team ||= begin
      ids = (direct_report_assignment_ids + delegated_assignment_ids).uniq
      scope = ids.empty? ? PersonFrameworkAssignment.none : PersonFrameworkAssignment.where(id: ids)
      preload(scope)
    end
  end

  # @return [ActiveRecord::Relation<PersonFrameworkAssignment>]
  def skip_level
    @skip_level ||= begin
      skip_person_ids = @person.all_reports.pluck(:id) - direct_report_person_ids
      scope =
        if skip_person_ids.empty?
          PersonFrameworkAssignment.none
        else
          team_ids = team.map(&:id)
          rel = PersonFrameworkAssignment.where(person_id: skip_person_ids)
          team_ids.any? ? rel.where.not(id: team_ids) : rel
        end
      preload(scope)
    end
  end

  private

  def preload(scope)
    scope.includes(:framework, :role, :level)
  end

  def direct_report_person_ids
    @direct_report_person_ids ||= @person.direct_reports.pluck(:id)
  end

  def direct_report_assignment_ids
    return [] if direct_report_person_ids.empty?

    PersonFrameworkAssignment.where(person_id: direct_report_person_ids).ids
  end

  # Assignment ids the person holds an active manager-rating delegation for.
  def delegated_assignment_ids
    pairs = ManagerAssessmentDelegation.active.for_delegate(@person.id)
      .pluck(:person_id, :framework_id)
    return [] if pairs.empty?

    pairs.map { |pid, fid| PersonFrameworkAssignment.where(person_id: pid, framework_id: fid) }
         .reduce(:or).ids
  end
end
