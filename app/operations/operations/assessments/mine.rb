# frozen_string_literal: true

# Lists the caller's own framework assignments plus the assignments they
# review — the data behind the web Assessments index, split the same way
# via {Assessments::ReviewableAssignments}: `direct_reports:` is the Team
# list (direct reports + assignments the caller holds an active
# manager-rating delegation for), `skip_level_reports:` is the view-only
# rest of their org subtree. Read-only; scoped by acts_as_tenant and
# AssessmentPolicy#index? (`person.present?`).
#
# Returns a single hash with `own:`, `direct_reports:`, and
# `skip_level_reports:` arrays so an MCP client can present them as
# separate lists without re-grouping. Each row includes enough identity,
# framework, and open-cycle context to pick the next drill-in
# (assessments_get) without an extra round trip.
class Operations::Assessments::Mine < Operations::Base
  description "List the caller's own assessment assignments plus the ones they review: their team's (direct reports and active rating delegations) and, view-only, their skip-level reports' assignments."
  category :read
  approval :none

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize PersonFrameworkAssignment, :index?
  end

  # @return [Hash{Symbol=>Array<Hash>}] three-key payload:
  #   - `:own` — assignments where the caller is the assessee. Each row has
  #     `:id, :framework{id,name,current_published_version}, :role{id,code,name},
  #     :level{id,ordinal,title}, :current_cycle{id,name,status,planned_end_at}|nil`.
  #   - `:direct_reports` — same shape, plus `:assessee{id,name,email}` for
  #     the person being assessed. Includes assignments the caller holds an
  #     active manager-rating delegation for, mirroring the web Team section.
  #   - `:skip_level_reports` — same shape as `:direct_reports`, for people
  #     deeper in the caller's org subtree (viewable, not ratable).
  def perform
    own = PersonFrameworkAssignment.for_person(context.person.id)
      .includes(:framework, :role, :level).to_a
    reviewable = Assessments::ReviewableAssignments.new(context.person)
    reports = reviewable.team.to_a
    skip_levels = reviewable.skip_level.to_a
    open_cycles = AssessmentCycle.open_cycles_for(cycle_keys(own + reports + skip_levels))
    people_by_id = Person.where(id: (reports + skip_levels).map(&:person_id)).index_by(&:id)

    {
      own: own.map { |a| serialize(a, open_cycles) },
      direct_reports: reports.map { |a| serialize(a, open_cycles, assessee: people_by_id[a.person_id]) },
      skip_level_reports: skip_levels.map { |a| serialize(a, open_cycles, assessee: people_by_id[a.person_id]) }
    }
  end

  private

  def cycle_keys(assignments)
    assignments.map { |a| [ a.framework_id, a.person_id ] }
  end

  def serialize(assignment, open_cycles, assessee: nil)
    row = {
      id: assignment.id,
      framework: framework_payload(assignment.framework),
      role: role_payload(assignment.role),
      level: level_payload(assignment.level),
      current_cycle: cycle_payload(open_cycles[[ assignment.framework_id, assignment.person_id ]])
    }
    row[:assessee] = person_payload(assessee) if assessee
    row
  end

  def framework_payload(framework)
    return nil unless framework

    { id: framework.framework_id, name: framework.name,
      current_published_version: framework.current_published_version }
  end

  def role_payload(role)
    role && { id: role.role_id, code: role.code, name: role.name }
  end

  def level_payload(level)
    level && { id: level.level_id, ordinal: level.ordinal, title: level.title }
  end

  def cycle_payload(cycle)
    return nil unless cycle

    {
      id: cycle.cycle_id,
      name: cycle.name,
      status: cycle.status,
      planned_end_at: cycle.planned_end_at&.iso8601
    }
  end

  def person_payload(person)
    { id: person.id, name: person.name, email: person.email }
  end
end
