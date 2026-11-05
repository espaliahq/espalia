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
#
# Filters narrow each source in SQL before its LIMIT. The rating and
# role-alignment rows keep only each cell's or role's latest stamp, so a
# window misses activity later overwritten; the event stream
# (`alignment_history:`) is the full record, one stream per assignment.
class Assessments::RecentActivityQuery
  DEFAULT_LIMIT = 8

  # A resolved, displayable activity item. `detail` carries a comment body
  # (nil otherwise); `reply` flags a comment that is a reply to another.
  # `role_id` and `home` are set on alignment milestones.
  Item = Data.define(
    :kind, :occurred_at, :person_id, :person_name, :actor_id, :actor_name,
    :framework_id, :assignment_id, :capability_stable_id, :capability_name, :level_ordinal,
    :detail, :reply, :role_id, :role_code, :role_name, :home
  ) do
    # Whether the actor differs from the assessee (e.g. a manager rated them).
    def actor_other? = actor_id.present? && actor_id != person_id
  end

  # Pre-resolution row gathered from a read model.
  Candidate = Data.define(:kind, :occurred_at, :person_id, :actor_id, :framework_id,
                          :capability_stable_id, :level_ordinal, :detail, :reply, :role_id, :home) do
    def initialize(role_id: nil, home: nil, **rest) = super
  end

  RATING_SOURCES = {
    "self_rated" => [ :last_self_rated_at, nil ],
    "manager_rated" => [ :last_manager_rated_at, :manager_rated_by_id ],
    "assessment_aligned" => [ :last_aligned_at, :aligned_by_id ]
  }.freeze

  ALIGNMENT_SOURCES = {
    "alignment_started" => [ :alignment_started_at, :alignment_started_by_id ],
    "alignment_completed" => [ :aligned_at, :aligned_by_id ],
    "alignment_reopened" => [ :reopened_at, :reopened_by_id ]
  }.freeze

  # The progress rows hold the home lifecycle and no re-open.
  HOME_ALIGNMENT_SOURCES = ALIGNMENT_SOURCES.except("alignment_reopened").freeze

  # What the Home card shows; `alignment_reopened` is asked for explicitly.
  DEFAULT_KINDS = %w[self_rated manager_rated assessment_aligned evidence_recorded comment_posted
                     alignment_started alignment_completed].freeze
  KINDS = (DEFAULT_KINDS + %w[alignment_reopened]).freeze

  # @param person_ids [Array<String>] assessees whose activity to include
  # @param limit [Integer] max items returned
  # @param since [Time, nil] keep activity at or after this
  # @param until_time [Time, nil] keep activity at or before this
  # @param cycle_id [String, nil] keep activity attributed to this cycle
  # @param kinds [Array<String>] keep these kinds (see {KINDS})
  # @param lens_alignments [Boolean] include alignments against other roles
  # @param alignment_history [Boolean] read alignment milestones from the
  #   event stream, re-opened completions included
  # @param framework_ids [Array<String>, nil] keep activity on these
  #   frameworks only — a viewer authorised per assessment; nil keeps all
  def initialize(person_ids:, limit: DEFAULT_LIMIT, since: nil, until_time: nil, cycle_id: nil,
                 kinds: DEFAULT_KINDS, lens_alignments: false, alignment_history: false, framework_ids: nil)
    @person_ids = Array(person_ids).compact.uniq
    @limit = limit
    @window = since || until_time ? (since..until_time) : nil
    @cycle_id = cycle_id
    @kinds = kinds
    @lens_alignments = lens_alignments
    @alignment_history = alignment_history
    @framework_ids = framework_ids
  end

  # Cheap existence check for card audience gating.
  # @return [Boolean]
  def any?
    return false if @person_ids.empty?

    RATING_SOURCES.any? { |_, (ts, _)| rating_relation(ts).exists? } ||
      EvidenceItem.active.where(person_id: @person_ids).exists? ||
      PersonDevelopmentComment.active.where(person_id: @person_ids).exists? ||
      HOME_ALIGNMENT_SOURCES.any? { |_, (ts, _)| progress_relation(ts).exists? }
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
    narrow(AssessmentLevelRating.across_all_roles.where(person_id: @person_ids).where.not(column => nil), column)
  end

  def alignment_relation(column)
    narrow(AssessmentCycleRoleAlignment.where(person_id: @person_ids).where.not(column => nil), column)
  end

  # Progress has no framework column; its cycle does.
  def progress_relation(column)
    relation = AssessmentCycleProgress.joins(:cycle).where(person_id: @person_ids).where.not(column => nil)
    relation = relation.where(column => @window) if @window
    relation = relation.where(cycle_id: @cycle_id) if @cycle_id
    relation = relation.where(assessment_cycles: { framework_id: @framework_ids }) if @framework_ids
    relation
  end

  # The window, the cycle and the frameworks, in SQL, before the caller's LIMIT.
  def narrow(relation, column, cycle: true)
    relation = relation.where(column => @window) if @window
    relation = relation.where(cycle_id: @cycle_id) if @cycle_id && cycle
    relation = relation.where(framework_id: @framework_ids) if @framework_ids
    relation
  end

  def wanted?(kind) = @kinds.include?(kind)

  def rating_candidates
    RATING_SOURCES.select { |kind, _| wanted?(kind) }.flat_map do |kind, (ts, actor_col)|
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
    return [] unless wanted?("evidence_recorded")

    narrow(EvidenceItem.active.where(person_id: @person_ids), :recorded_at)
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
    return [] if !wanted?("comment_posted") || @cycle_id

    narrow(PersonDevelopmentComment.active.where(person_id: @person_ids), :posted_at, cycle: false)
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
    return alignment_history_candidates if @alignment_history

    return home_alignment_candidates unless @lens_alignments

    ALIGNMENT_SOURCES.select { |kind, _| wanted?(kind) }.flat_map do |kind, (ts, actor_col)|
      alignment_relation(ts).order(ts => :desc).limit(@limit)
        .pluck(:person_id, :framework_id, ts, actor_col, :role_id, :home)
        .map do |person_id, framework_id, occurred_at, actor_id, role_id, home|
          Candidate.new(
            kind: kind, occurred_at: occurred_at, person_id: person_id, actor_id: actor_id,
            framework_id: framework_id, capability_stable_id: nil, level_ordinal: nil,
            detail: nil, reply: false, role_id: role_id, home: home
          )
        end
    end
  end

  # The home lifecycle's milestones, as the card has always shown them.
  def home_alignment_candidates
    HOME_ALIGNMENT_SOURCES.select { |kind, _| wanted?(kind) }.flat_map do |kind, (ts, actor_col)|
      progress_relation(ts).order(ts => :desc).limit(@limit)
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

  # Every alignment milestone in each person's stream, not only the latest.
  def alignment_history_candidates
    kinds = ALIGNMENT_SOURCES.keys.select { |kind| wanted?(kind) }
    return [] if kinds.empty?

    assignments = PersonFrameworkAssignment.where(person_id: @person_ids)
    assignments = assignments.where(framework_id: @framework_ids) if @framework_ids
    assignments.flat_map do |assignment|
      Assessments::LifecycleTimeline.new(assignment: assignment).call(cycle_id: @cycle_id, kinds: kinds)
        .select { |m| (@lens_alignments || m.home) && (@window.nil? || @window.cover?(m.occurred_at)) }
        .map do |m|
          Candidate.new(
            kind: m.kind, occurred_at: m.occurred_at, person_id: assignment.person_id, actor_id: m.actor_id,
            framework_id: assignment.framework_id, capability_stable_id: nil,
            level_ordinal: nil, detail: nil, reply: false, role_id: m.role_id, home: m.home
          )
        end
    end
  end

  # Bulk-resolve names, assignment ids, and capability names for the capped set.
  def resolve(candidates)
    names = person_names(candidates)
    assignments = assignment_index(candidates)
    cap_names = capability_names(candidates)
    roles = role_index(candidates)

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
        reply: candidate.reply,
        role_id: candidate.role_id,
        role_code: candidate.role_id && roles[candidate.role_id]&.code,
        role_name: candidate.role_id && roles[candidate.role_id]&.name,
        home: candidate.home
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

  def role_index(candidates)
    role_ids = candidates.filter_map(&:role_id).uniq
    return {} if role_ids.empty?

    FrameworkState::Role.where(role_id: role_ids).index_by(&:role_id)
  end

  def capability_names(candidates)
    stable_ids = candidates.filter_map(&:capability_stable_id).uniq
    return {} if stable_ids.empty?

    FrameworkState::Capability.where(stable_id: stable_ids).pluck(:stable_id, :name).to_h
  end
end
