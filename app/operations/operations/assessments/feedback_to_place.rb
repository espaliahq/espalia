# frozen_string_literal: true

# "What feedback is waiting for me to place?" — the hub's "Feedback to place"
# list, shared by the web and MCP. Unplaced items about the caller, and about
# the people they place feedback for in one of two views
# ({Assessments::FeedbackToPlace}): `team` (default — direct reports and
# active rating delegations) or `org` (team plus everyone deeper in the
# subtree). The view narrows what is listed, never who may place it.
# Read-only; any member with a Person record (AssessmentPolicy#index?).
class Operations::Assessments::FeedbackToPlace < Operations::Base
  EXCERPT_LENGTH = 200

  description "List feedback waiting for you to place on a capability: items about you, and items about the people " \
              "you place feedback for. scope \"team\" (the default) covers your direct reports and the assessments " \
              "you hold a rating delegation for; \"org\" adds everyone deeper in your org. counts gives both sizes, " \
              "so you can tell when more waits beyond your team. Each item carries its assignment_id; place one " \
              "with assessments_add_evidence_link, or read its pending suggestions with " \
              "assessments_evidence_suggestions_list."
  category :read
  approval :none

  parameter :scope, String, allowed: ::Assessments::FeedbackToPlace::SCOPES

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize PersonFrameworkAssignment, :index?
  end

  # @return [Hash] `{ scope:, beyond_team:, counts: { team:, org: }, about_you: [...], items: [...] }`.
  #   `beyond_team` is false when the org view would list no one the team
  #   view doesn't. `items` holds the chosen scope's items; each item, in
  #   either list, is `{ evidence_id, assignment_id, person{id,name},
  #   framework{id,name}, kind, custom_type_label, origin{system,label,url},
  #   author{id,name}, recorded_at, excerpt }`, oldest first. `origin.system`
  #   is "growthos" for feedback given here and the peer's slug ("chip") for
  #   imported feedback, whose `url` opens the original.
  def perform
    query = ::Assessments::FeedbackToPlace.new(context.person)
    team_items = query.items("team")
    org_items = query.items("org")
    in_scope = scope == "org" ? org_items : team_items
    assignments = query.assignments(scope).merge(own_assignments)
    people = Person.where(id: in_scope.map(&:person_id).uniq).index_by(&:id)
    people[context.person.id] = context.person

    {
      scope: scope,
      beyond_team: query.beyond_team?,
      counts: { team: team_items.size, org: org_items.size },
      about_you: query.about_viewer.map { |item| item_payload(item, assignments, people) },
      items: in_scope.map { |item| item_payload(item, assignments, people) }
    }
  end

  private

  def scope
    params[:scope].presence || ::Assessments::FeedbackToPlace::DEFAULT_SCOPE
  end

  def own_assignments
    PersonFrameworkAssignment.for_person(context.person.id).includes(:framework)
      .index_by { |a| [ a.person_id, a.framework_id ] }
  end

  def item_payload(item, assignments, people)
    assignment = assignments[[ item.person_id, item.framework_id ]]
    person = people[item.person_id]
    {
      evidence_id: item.id,
      assignment_id: assignment&.id,
      person: { id: item.person_id, name: person&.name },
      framework: { id: item.framework_id, name: assignment&.framework&.name },
      kind: item.evidence_type,
      custom_type_label: item.custom_type_label,
      origin: origin_payload(item.external_reference),
      author: { id: item.author_id, name: item.author&.name },
      recorded_at: item.recorded_at&.iso8601,
      excerpt: Prose.to_plain(item.content).squish.truncate(EXCERPT_LENGTH)
    }
  end

  def origin_payload(reference)
    imported = reference&.imported?
    system = imported ? Reporting::OriginLabels.key_for(reference.system, imported: true) : Reporting::OriginLabels::NATIVE
    { system: system, label: Reporting::OriginLabels.peer_label(system), url: (reference.safe_url if imported) }
  end
end
