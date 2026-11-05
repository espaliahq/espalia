# frozen_string_literal: true

# Shares {Assessments::RecentActivityQuery} with the Home "Recent activity"
# card, which keeps its own narrower scope.
class Operations::Assessments::RecentActivity < Operations::Base
  DATE_ONLY = /\A\d{4}-\d{2}-\d{2}\z/
  WITH_OFFSET = /(Z|[+-]\d{2}:?\d{2})\z/

  description "Recent assessment activity, most recent first (metadata only, no rating values): " \
              "ratings, evidence, comments, and alignment milestones started, completed and " \
              "re-opened against any role (role_id, role_code, role_name, home). Covers the caller " \
              "and their whole org subtree; person_id narrows to one person whose assessment the " \
              "caller may view, and then alignment milestones come from the event stream, so a " \
              "completion later re-opened still appears. since / until (ISO 8601; a bare date is " \
              "its UTC day, inclusive; a date-time needs an offset) bound the window, applied before " \
              "the limit. Ratings and alignment rows keep only each cell's or role's latest stamp, " \
              "so a window misses activity later overwritten (with person_id, alignments are read " \
              "in full from the stream). cycle_id keeps one cycle's activity " \
              "(comments carry no cycle and are left out). kinds narrows by kind; an empty list " \
              "returns none. limit defaults to 8, at most 50."
  category :read
  approval :none

  DEFAULT_LIMIT = 8
  MAX_LIMIT = 50

  parameter :limit, Integer, required: false
  parameter :person_id, String, required: false, allow_blank: false
  parameter :since, String, required: false, allow_blank: false,
    schema: { description: "ISO 8601 date-time, or a date for the start of that UTC day." }
  parameter :until, String, required: false, allow_blank: false,
    schema: { description: "ISO 8601 date-time, or a date for the end of that UTC day." }
  parameter :cycle_id, String, required: false, allow_blank: false,
    schema: Operations::Reporting::CyclesList::CYCLE_ID_SCHEMA
  parameter :kinds, Array, required: false,
    schema: { type: "array", items: { type: "string", enum: Assessments::RecentActivityQuery::KINDS },
              description: "Keep only these kinds of activity." }

  # @raise [Pundit::NotAuthorizedError] when the caller has no person, or
  #   names a person whose assessment they may not view
  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize PersonFrameworkAssignment, :index?
    return if params[:person_id].blank? || context.tenant_admin? || scope_person_ids.include?(params[:person_id])
    return if PersonFrameworkAssignment.where(person_id: params[:person_id])
      .any? { |assignment| AssessmentPolicy.new(context, assignment).show? }

    raise Pundit::NotAuthorizedError, "you may not view that person's assessment"
  end

  # @return [Hash] `{ activity: [...] }`, most recent first
  # @raise [Operations::Base::ParameterError] for an unreadable time or an unknown kind
  def perform
    since = time_param(:since, :beginning_of_day)
    until_time = time_param(:until, :end_of_day)
    raise ParameterError, "since must not be after until" if since && until_time && since > until_time

    items = Assessments::RecentActivityQuery.new(
      person_ids: params[:person_id].presence ? [ params[:person_id] ] : scope_person_ids,
      limit: limit, since: since, until_time: until_time,
      cycle_id: params[:cycle_id].presence, kinds: kinds,
      lens_alignments: true, alignment_history: params[:person_id].present?
    ).call

    { activity: items.map { |item| serialize(item) } }
  end

  private

  # The caller and everyone below them.
  def scope_person_ids
    @scope_person_ids ||= [ context.person.id, *context.person.all_reports.pluck(:id) ]
  end

  def kinds
    return Assessments::RecentActivityQuery::KINDS if params[:kinds].nil?

    requested = Array(params[:kinds])
    unknown = requested - Assessments::RecentActivityQuery::KINDS
    raise ParameterError, "unknown kinds: #{unknown.join(', ')}" if unknown.any?

    requested
  end

  # A bare date is its UTC day; a date-time must say its offset.
  def time_param(name, day_edge)
    value = params[name]
    return nil if value.blank?
    return Date.iso8601(value).in_time_zone("UTC").public_send(day_edge) if DATE_ONLY.match?(value)
    raise ArgumentError unless WITH_OFFSET.match?(value)

    Time.iso8601(value)
  rescue ArgumentError
    raise ParameterError, "#{name} must be ISO 8601: a date (YYYY-MM-DD) or a date-time with an offset"
  end

  def limit
    requested = params[:limit].to_i
    requested.positive? ? [ requested, MAX_LIMIT ].min : DEFAULT_LIMIT
  end

  def serialize(item)
    row = {
      kind: item.kind,
      occurred_at: item.occurred_at&.getutc&.iso8601,
      person: { id: item.person_id, name: item.person_name },
      actor: item.actor_other? ? { id: item.actor_id, name: item.actor_name } : nil,
      framework_id: item.framework_id,
      assignment_id: item.assignment_id,
      capability: item.capability_stable_id && { stable_id: item.capability_stable_id, name: item.capability_name },
      level_ordinal: item.level_ordinal
    }
    row.merge!(role_id: item.role_id, role_code: item.role_code, role_name: item.role_name, home: item.home) if item.role_id
    row[:detail] = item.detail if item.detail.present?
    row[:reply] = item.reply if item.kind == "comment_posted"
    row
  end
end
