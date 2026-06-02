# frozen_string_literal: true

# Recent assessment activity across a set of people, assembled cheaply from
# read models. Powers the Home "Recent activity" card — for an IC, their own
# assessment activity; for a manager, their direct reports'.
#
# Deliberately does NOT use {Assessments::ActivityFeedQuery}: that replays the
# full PersonDevelopment event stream per assignment (O(people × stream)), which
# is fine for one assessee's detailed feed but far too heavy to fan out across a
# manager's reports. Instead each activity surface is read from its projection
# read model with a bounded `ORDER ... LIMIT`, then merged and capped. Read-only
# and tenant-scoped (the read models are `acts_as_tenant`).
class Assessments::RecentActivityQuery
  DEFAULT_LIMIT = 8

  # A resolved, displayable activity item. `detail` carries a comment body
  # (nil otherwise); `reply` flags a comment that is a reply to another.
  Item = Data.define(
    :kind, :occurred_at, :person_id, :person_name, :actor_id, :actor_name,
    :framework_id, :assignment_id, :capability_stable_id, :capability_name, :level_ordinal,
    :detail, :reply
  ) do
    # Whether the actor differs from the assessee (e.g. a manager rated them).
    def actor_other? = actor_id.present? && actor_id != person_id
  end

  # Pre-resolution row gathered from a read model.
  Candidate = Data.define(:kind, :occurred_at, :person_id, :actor_id, :framework_id,
                          :capability_stable_id, :level_ordinal, :detail, :reply)

  RATING_SOURCES = {
    "self_rated" => [ :last_self_rated_at, nil ],
    "manager_rated" => [ :last_manager_rated_at, :manager_rated_by_id ],
    "assessment_aligned" => [ :last_aligned_at, :aligned_by_id ]
  }.freeze

  ALIGNMENT_SOURCES = {
    "alignment_started" => [ :alignment_started_at, :alignment_started_by_id ],
    "alignment_completed" => [ :aligned_at, :aligned_by_id ]
  }.freeze

  # @param person_ids [Array<String>] assessees whose activity to include
  # @param limit [Integer] max items returned
  def initialize(person_ids:, limit: DEFAULT_LIMIT)
    @person_ids = Array(person_ids).compact.uniq
    @limit = limit
  end

  # Cheap existence check for card audience gating.
  # @return [Boolean]
  def any?
    return false if @person_ids.empty?

    RATING_SOURCES.any? { |_, (ts, _)| rating_relation(ts).exists? } ||
      EvidenceItem.active.where(person_id: @person_ids).exists? ||
      PersonDevelopmentComment.active.where(person_id: @person_ids).exists? ||
      ALIGNMENT_SOURCES.any? { |_, (ts, _)| progress_relation(ts).exists? }
  end

  # @return [Array<Item>] most-recent-first, capped at `limit`.
  def call
    return [] if @person_ids.empty?

    candidates = (rating_candidates + evidence_candidates + comment_candidates + alignment_candidates)
      .sort_by(&:occurred_at).reverse.first(@limit)

    resolve(candidates)
  end

  private

  def rating_relation(column)
    AssessmentLevelRating.where(person_id: @person_ids).where.not(column => nil)
  end

  def progress_relation(column)
    AssessmentCycleProgress.where(person_id: @person_ids).where.not(column => nil)
  end

  def rating_candidates
    RATING_SOURCES.flat_map do |kind, (ts, actor_col)|
      columns = [ :person_id, :framework_id, :capability_stable_id, :level_ordinal, ts ]
      columns << actor_col if actor_col

      rating_relation(ts).order(ts => :desc).limit(@limit).pluck(*columns).map do |row|
        person_id, framework_id, stable_id, ordinal, occurred_at = row
        Candidate.new(
          kind: kind, occurred_at: occurred_at, person_id: person_id,
          actor_id: actor_col ? row.last : person_id, framework_id: framework_id,
          capability_stable_id: stable_id, level_ordinal: ordinal, detail: nil, reply: false
        )
      end
    end
  end

  def evidence_candidates
    EvidenceItem.active.where(person_id: @person_ids)
      .order(recorded_at: :desc).limit(@limit)
      .pluck(:person_id, :framework_id, :capability_stable_id, :level_ordinal, :recorded_at, :author_id)
      .map do |person_id, framework_id, stable_id, ordinal, occurred_at, author_id|
        Candidate.new(
          kind: "evidence_recorded", occurred_at: occurred_at, person_id: person_id,
          actor_id: author_id, framework_id: framework_id,
          capability_stable_id: stable_id, level_ordinal: ordinal, detail: nil, reply: false
        )
      end
  end

  def comment_candidates
    PersonDevelopmentComment.active.where(person_id: @person_ids)
      .order(posted_at: :desc).limit(@limit)
      .pluck(:person_id, :framework_id, :capability_stable_id, :level_ordinal, :posted_at,
             :author_id, :body, :parent_id)
      .map do |person_id, framework_id, stable_id, ordinal, occurred_at, author_id, body, parent_id|
        Candidate.new(
          kind: "comment_posted", occurred_at: occurred_at, person_id: person_id,
          actor_id: author_id, framework_id: framework_id,
          capability_stable_id: stable_id, level_ordinal: ordinal,
          detail: body, reply: parent_id.present?
        )
      end
  end

  def alignment_candidates
    ALIGNMENT_SOURCES.flat_map do |kind, (ts, actor_col)|
      progress_relation(ts).joins(:cycle).order(ts => :desc).limit(@limit)
        .pluck(:person_id, "assessment_cycles.framework_id", ts, actor_col)
        .map do |person_id, framework_id, occurred_at, actor_id|
          Candidate.new(
            kind: kind, occurred_at: occurred_at, person_id: person_id, actor_id: actor_id,
            framework_id: framework_id, capability_stable_id: nil, level_ordinal: nil,
            detail: nil, reply: false
          )
        end
    end
  end

  # Bulk-resolve names, assignment ids, and capability names for the capped set.
  def resolve(candidates)
    names = person_names(candidates)
    assignments = assignment_index(candidates)
    cap_names = capability_names(candidates)

    candidates.map do |candidate|
      Item.new(
        kind: candidate.kind,
        occurred_at: candidate.occurred_at,
        person_id: candidate.person_id,
        person_name: names[candidate.person_id] || "Unknown",
        actor_id: candidate.actor_id,
        actor_name: candidate.actor_id && names[candidate.actor_id],
        framework_id: candidate.framework_id,
        assignment_id: assignments[[ candidate.person_id, candidate.framework_id ]],
        capability_stable_id: candidate.capability_stable_id,
        capability_name: candidate.capability_stable_id && cap_names[candidate.capability_stable_id],
        level_ordinal: candidate.level_ordinal,
        detail: candidate.detail,
        reply: candidate.reply
      )
    end
  end

  def person_names(candidates)
    ids = candidates.flat_map { |c| [ c.person_id, c.actor_id ] }.compact.uniq
    return {} if ids.empty?

    Person.where(id: ids).pluck(:id, :name).to_h
  end

  def assignment_index(candidates)
    pairs = candidates.map { |c| [ c.person_id, c.framework_id ] }.uniq
    return {} if pairs.empty?

    PersonFrameworkAssignment
      .where(person_id: pairs.map(&:first).uniq, framework_id: pairs.map(&:last).uniq)
      .pluck(:person_id, :framework_id, :id)
      .each_with_object({}) { |(person_id, framework_id, id), index| index[[ person_id, framework_id ]] = id }
  end

  def capability_names(candidates)
    stable_ids = candidates.filter_map(&:capability_stable_id).uniq
    return {} if stable_ids.empty?

    FrameworkState::Capability.where(stable_id: stable_ids).pluck(:stable_id, :name).to_h
  end
end
