# frozen_string_literal: true

# Unplaced feedback a person may place for someone, split the way the hub's
# "Feedback to place" toggle and `assessments_feedback_to_place` show it:
#
# - {#about_viewer} — items about the person themselves.
# - `team` — items about their team: the assignments in
#   {Assessments::ReviewableAssignments#team} (direct reports plus active
#   manager-rating delegations).
# - `org` — team plus everyone deeper in their subtree
#   ({Assessments::ReviewableAssignments#skip_level}).
#
# A view filter, never authority: EvidencePolicy#add_link? still lets an
# ancestor place anything in their subtree. Items the person wrote are left
# out; the hub lists them under the feedback they've given.
class Assessments::FeedbackToPlace
  SCOPES = %w[team org].freeze
  DEFAULT_SCOPE = "team"

  # @param viewer [Person]
  def initialize(viewer)
    @viewer = viewer
    @reviewable = Assessments::ReviewableAssignments.new(viewer)
  end

  # @return [Array<EvidenceItem>] oldest first
  def about_viewer
    @about_viewer ||= unplaced.for_person(@viewer.id).to_a
  end

  # @param scope [String] "team" or "org"
  # @return [Array<EvidenceItem>] oldest first, never about the viewer
  def items(scope)
    keys = assignments(scope).keys.to_set
    org_items.select { |item| keys.include?(key_for(item)) }
  end

  # @param scope [String] "team" or "org"
  # @return [Hash{Array(String, String) => PersonFrameworkAssignment}] the
  #   assignments in scope, keyed by `[person_id, framework_id]`
  def assignments(scope)
    scope == "org" ? org_assignments : team_assignments
  end

  # Whether the org view reaches anyone the team view doesn't — the toggle
  # has nothing to switch otherwise.
  #
  # @return [Boolean]
  def beyond_team?
    org_assignments.size > team_assignments.size
  end

  # The scope whose list holds feedback about this person's assessment, so a
  # link from elsewhere lands on a page where the card exists.
  #
  # @return [String, nil] "team", "org", or nil when it is about the viewer
  #   or outside both views
  def scope_for(person_id, framework_id)
    key = [ person_id, framework_id ]
    return "team" if team_assignments.key?(key)

    "org" if org_assignments.key?(key)
  end

  # The hub path that shows this feedback's card: the org view when only the
  # org view lists it.
  #
  # @param item [EvidenceItem]
  # @return [String]
  def hub_path(item)
    place = scope_for(item.person_id, item.framework_id) == "org" ? "org" : nil
    EvidenceItem.hub_path(item.id, place: place)
  end

  private

  def unplaced
    EvidenceItem.unplaced.where.not(author_id: @viewer.id).includes(:author).order(:recorded_at, :id)
  end

  def org_items
    @org_items ||= begin
      keys = org_assignments.keys.to_set
      person_ids = keys.map(&:first).uniq
      person_ids.empty? ? [] : unplaced.where(person_id: person_ids).select { |item| keys.include?(key_for(item)) }
    end
  end

  def team_assignments
    @team_assignments ||= index(@reviewable.team)
  end

  def org_assignments
    @org_assignments ||= team_assignments.merge(index(@reviewable.skip_level))
  end

  def index(relation)
    relation.reject { |a| a.person_id == @viewer.id }.index_by { |a| [ a.person_id, a.framework_id ] }
  end

  def key_for(item) = [ item.person_id, item.framework_id ]
end
