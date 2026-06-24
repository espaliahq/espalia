# frozen_string_literal: true

# Resolves who a requester can ask for evidence on a cell-scoped assessment
# request — both the typeahead **search** (by name or email) and the **quick-add
# suggestions** (the assessee's org neighbours: manager, peers, direct reports).
#
# Both surfaces apply the same rules:
#   - hard-exclude the assessee (you can't ask them about themselves) and the
#     requester (asking yourself is pointless);
#   - flag anyone who already has a **pending** request on this exact cell as
#     `already_requested` so the UI can grey them out (block re-asking) rather
#     than hide them.
#
# Tenant scoping is automatic via acts_as_tenant on Person / EvidenceRequest.
#
# @example
#   q = Assessments::RequestCandidates.new(
#     assignment:, requester_person_id:, capability_stable_id:, level_ordinal:
#   )
#   q.suggestions        # => [Candidate(relation: :manager), Candidate(relation: :peer), …]
#   q.search("pri")      # => [Candidate(person:, already_requested:, relation: nil), …]
class Assessments::RequestCandidates
  SEARCH_LIMIT = 3

  # @!attribute person [Person]
  # @!attribute already_requested [Boolean] a pending request exists on this cell
  # @!attribute relation [Symbol, nil] :manager / :peer / :report for suggestions
  Candidate = Data.define(:person, :already_requested, :relation)

  # @param assignment [PersonFrameworkAssignment] fixes assessee + framework
  # @param requester_person_id [String] the person doing the asking
  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  def initialize(assignment:, requester_person_id:, capability_stable_id:, level_ordinal:)
    @assignment = assignment
    @requester_person_id = requester_person_id
    @capability_stable_id = capability_stable_id
    @level_ordinal = level_ordinal
  end

  # Typeahead results for a free-text query over name/email.
  #
  # @param query [String, nil]
  # @param limit [Integer]
  # @return [Array<Candidate>] empty when the query is blank
  def search(query, limit: SEARCH_LIMIT)
    return [] if query.blank?

    term = "%#{sanitize_like(query.strip)}%"
    scope = selectable
      .where("people.name ILIKE :t OR people.email ILIKE :t", t: term)
      .order(:name)
      .limit(limit)
    scope.map { |person| candidate(person, relation: nil) }
  end

  # Quick-add suggestions, de-duplicated and excluding only the requester (you
  # can't ask yourself). The assessee first (a manager can ask them for more
  # evidence), then their manager, peers, and direct reports.
  #
  # @return [Array<Candidate>]
  def suggestions
    seen = Set.new
    [ *assessee_candidate, *manager_candidates, *peer_candidates, *report_candidates ].filter_map do |person, relation|
      next if person.nil? || excluded_id?(person.id) || !seen.add?(person.id)

      candidate(person, relation:)
    end
  end

  private

  attr_reader :assignment, :requester_person_id, :capability_stable_id, :level_ordinal

  def assessee
    @assessee ||= Person.find(assignment.person_id)
  end

  # Active people in the tenant, minus the requester (you can't ask yourself).
  # The assessee IS selectable. Already-pending people are NOT excluded here —
  # they're flagged instead.
  def selectable
    Person.active.where.not(id: requester_person_id)
  end

  def candidate(person, relation:)
    Candidate.new(person:, already_requested: pending_requestee_ids.include?(person.id), relation:)
  end

  def excluded_id?(id)
    id == requester_person_id
  end

  def assessee_candidate
    [ [ assessee, :assessee ] ]
  end

  # Requestee ids with a pending request on this exact cell.
  def pending_requestee_ids
    @pending_requestee_ids ||= EvidenceRequest
      .for_assessment(assessee.id, assignment.framework_id)
      .pending
      .where(capability_stable_id:, level_ordinal:)
      .pluck(:requestee_person_id)
      .to_set
  end

  def manager_candidates
    [ [ assessee.manager, :manager ] ]
  end

  def peer_candidates
    return [] if assessee.manager.nil?

    assessee.manager.direct_reports.active.order(:name).map { |p| [ p, :peer ] }
  end

  def report_candidates
    assessee.direct_reports.active.order(:name).map { |p| [ p, :report ] }
  end

  # Escape LIKE wildcards so a user's "%" / "_" is matched literally.
  def sanitize_like(value)
    value.gsub(/[\\%_]/) { |char| "\\#{char}" }
  end
end
