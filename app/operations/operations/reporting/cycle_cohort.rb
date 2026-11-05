# frozen_string_literal: true

# Aggregate progress roll-up for an assessment cycle, shared by the web cohort
# view and the MCP server. Scoped to the caller's org subtree (admins/HR see the
# whole cycle). Exposes lifecycle status and timestamps, never rating values:
# the manager chain may see everything about a person, but this is a progress
# report.
#
# Incremental disclosure: defaults to `summary` (funnel + counts + the most
# lagging subtree). Pass `mode: "full"` for the per-participant breakdown.
class Operations::Reporting::CycleCohort < Operations::Base
  DATE_FORMAT = "[0-9]{4}-[0-9]{2}-[0-9]{2}"
  DATE_PATTERN = "^#{DATE_FORMAT}$"
  DATE_KEY = /\A#{DATE_FORMAT}\z/

  description "Aggregate progress for an assessment cycle across the caller's org subtree " \
              "(admins see the whole cycle): the self/manager/aligned funnel, lifecycle status " \
              "counts, at-risk count, the cycle's opened/closed times and the median days from " \
              "enrolment to alignment. In full mode, grouped breakdowns and per-participant " \
              "progress with when each milestone happened (enrolled, self and manager assessment " \
              "complete, alignment started and completed, with who acted) and every role " \
              "alignment, including re-opens. Timestamps are ISO 8601 UTC and record the LATEST " \
              "occurrence: a re-open clears aligned_at until the next completion. The self/manager " \
              "completion stamps update on rating events only, so after a role or framework " \
              "change they can disagree with self_done / manager_done until the next rating. " \
              "aligned_from / aligned_to (full mode only, UTC dates, inclusive) narrow the " \
              "participant list to those with an alignment, against any role, completed in that " \
              "window. Returns no rating values."
  category :read
  approval :none

  parameter :cycle_id, String, required: true
  parameter :mode, String, required: false, allowed: %w[summary full]
  parameter :scope, String, required: false, allowed: %w[mine all]
  parameter :aligned_from, String, required: false, allow_blank: false,
    schema: { pattern: DATE_PATTERN, description: "UTC date, YYYY-MM-DD. Full mode only." }
  parameter :aligned_to, String, required: false, allow_blank: false,
    schema: { pattern: DATE_PATTERN, description: "UTC date, YYYY-MM-DD, inclusive. Full mode only." }

  %i[aligned_from aligned_to].each do |name|
    dependent_required name, requires: :mode
    forbids_when name, if: :mode, equals: "summary"
  end

  def policy_check
    authorize cycle, :cohort?
  end

  def perform
    window = aligned_window
    result = ::Reporting::CycleCohort.new(
      cycle: cycle,
      scope_person_ids: scope_person_ids,
      mode: mode,
      include_role_alignments: mode == :full
    ).call

    serialize(result, window)
  end

  private

  def cycle
    @cycle ||= AssessmentCycle.find_by!(cycle_id: params[:cycle_id])
  end

  def mode
    params[:mode] == "full" ? :full : :summary
  end

  def policy
    @policy ||= AssessmentCyclePolicy.new(context, cycle)
  end

  # nil = whole cycle; otherwise the caller's org subtree. Non-admins are
  # always scoped; admins/HR see the whole cycle unless they pass scope: "mine".
  def scope_person_ids
    return context.person&.all_reports&.pluck(:id) || [] if scope_to_subtree?

    nil
  end

  def scope_to_subtree?
    !policy.cohort_full_access? || params[:scope] == "mine"
  end

  # @return [Range<ActiveSupport::TimeWithZone>, nil]
  def aligned_window
    return nil if params[:aligned_from].blank? && params[:aligned_to].blank?

    from = parse_date(:aligned_from)&.beginning_of_day
    to = parse_date(:aligned_to)&.end_of_day
    raise ParameterError, "aligned_from must not be after aligned_to" if from && to && from > to

    from..to
  end

  def parse_date(name)
    value = params[name]
    return nil if value.blank?
    raise ParameterError, "#{name} must be a date, YYYY-MM-DD" unless DATE_KEY.match?(value)

    Date.iso8601(value).in_time_zone("UTC")
  rescue Date::Error
    raise ParameterError, "#{name} must be a date, YYYY-MM-DD"
  end

  def aligned_in?(participant, window)
    times = [ participant.lifecycle.aligned_at, *participant.role_alignments.map(&:aligned_at) ]
    times.compact.any? { |time| window.cover?(time) }
  end

  def serialize(result, window)
    participants = result.participants
    participants = participants.select { |p| aligned_in?(p, window) } if window

    {
      cycle: {
        id: result.cycle.cycle_id,
        name: result.cycle.name,
        status: result.cycle.status,
        opened_at: iso(result.cycle.opened_at),
        planned_end_at: result.cycle.planned_end_at,
        closed_at: iso(result.cycle.closed_at)
      },
      total: result.total,
      funnel: funnel_payload(result.funnel),
      status_counts: result.status_counts,
      at_risk_count: result.at_risk_count,
      median_days_to_align: result.median_days_to_align,
      top_lagging_group: group_payload(result.top_lagging_group),
      groups: result.groups.transform_values { |list| list.map { |group| group_payload(group) } },
      participants: participant_payloads(participants)
    }
  end

  def funnel_payload(funnel)
    {
      enrolled: funnel.enrolled,
      self_done: funnel.self_done, self_pct: funnel.self_pct,
      manager_done: funnel.manager_done, manager_pct: funnel.manager_pct,
      aligned: funnel.aligned, aligned_pct: funnel.aligned_pct
    }
  end

  def group_payload(group)
    return nil unless group

    {
      label: group.label,
      total: group.total,
      aligned_pct: group.funnel.aligned_pct,
      at_risk_count: group.at_risk_count
    }
  end

  def participant_payloads(participants)
    actors = actor_names(participants)
    participants.map { |participant| participant_payload(participant, actors) }
  end

  # @return [Hash{String => String}] person id => name, for every actor named
  def actor_names(participants)
    ids = participants.flat_map do |p|
      [ p.lifecycle.alignment_started_by_id, p.lifecycle.aligned_by_id ] +
        p.role_alignments.flat_map { |a| [ a.alignment_started_by_id, a.aligned_by_id, a.reopened_by_id ] }
    end.compact.uniq
    ids.empty? ? {} : Person.where(id: ids).pluck(:id, :name).to_h
  end

  def participant_payload(participant, actors)
    lifecycle = participant.lifecycle
    {
      person_id: participant.person_id,
      name: participant.name,
      role: participant.role_name,
      level_ordinal: participant.level_ordinal,
      status: participant.status,
      self_done: participant.self_done,
      manager_done: participant.manager_done,
      aligned: participant.aligned,
      at_risk: participant.at_risk,
      enrolled_at: iso(lifecycle.enrolled_at),
      started_at: iso(lifecycle.started_at),
      self_completed_at: iso(lifecycle.self_completed_at),
      manager_completed_at: iso(lifecycle.manager_completed_at),
      alignment_started_at: iso(lifecycle.alignment_started_at),
      alignment_started_by: actor(lifecycle.alignment_started_by_id, actors),
      aligned_at: iso(lifecycle.aligned_at),
      aligned_by: actor(lifecycle.aligned_by_id, actors),
      aligned_framework_version: lifecycle.aligned_framework_version,
      last_activity_at: iso(participant.last_activity_at),
      role_alignments: participant.role_alignments.map { |alignment| role_alignment_payload(alignment, actors) }
    }
  end

  def role_alignment_payload(alignment, actors)
    {
      role_id: alignment.role_id,
      role_name: alignment.role_name,
      home: alignment.home,
      status: alignment.status,
      alignment_started_at: iso(alignment.alignment_started_at),
      alignment_started_by: actor(alignment.alignment_started_by_id, actors),
      aligned_at: iso(alignment.aligned_at),
      aligned_by: actor(alignment.aligned_by_id, actors),
      reopened_at: iso(alignment.reopened_at),
      reopened_by: actor(alignment.reopened_by_id, actors)
    }
  end

  def actor(id, actors)
    id && { id: id, name: actors[id] }
  end

  def iso(time)
    time&.utc&.iso8601
  end
end
