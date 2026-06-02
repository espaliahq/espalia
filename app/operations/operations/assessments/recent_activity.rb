# frozen_string_literal: true

# Recent assessment activity for the caller — their own assessment activity as
# an IC, or their direct reports' as a manager (ratings, evidence, comments,
# alignment milestones). Shares {Assessments::RecentActivityQuery} with the Home
# "Recent activity" card. Read-only and scoped to the caller's own people; emits
# event metadata (kind, who, which capability, when) but never rating values.
class Operations::Assessments::RecentActivity < Operations::Base
  description "Recent assessment activity for the caller — their own as an IC, or their direct " \
              "reports' as a manager: ratings, evidence, comments, and alignment milestones " \
              "(metadata only, no rating values), most-recent first."
  category :read
  approval :none

  DEFAULT_LIMIT = 8
  MAX_LIMIT = 50

  parameter :limit, Integer, required: false

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize PersonFrameworkAssignment, :index?
  end

  def perform
    items = Assessments::RecentActivityQuery.new(person_ids: scope_person_ids, limit: limit).call

    { activity: items.map { |item| serialize(item) } }
  end

  private

  # IC → own activity; manager → direct reports'.
  def scope_person_ids
    context.person.direct_reports.pluck(:id).presence || [ context.person.id ]
  end

  def limit
    requested = params[:limit].to_i
    requested.positive? ? [ requested, MAX_LIMIT ].min : DEFAULT_LIMIT
  end

  def serialize(item)
    row = {
      kind: item.kind,
      occurred_at: item.occurred_at&.iso8601,
      person: { id: item.person_id, name: item.person_name },
      actor: item.actor_other? ? { id: item.actor_id, name: item.actor_name } : nil,
      framework_id: item.framework_id,
      assignment_id: item.assignment_id,
      capability: item.capability_stable_id && { stable_id: item.capability_stable_id, name: item.capability_name },
      level_ordinal: item.level_ordinal
    }
    row[:detail] = item.detail if item.detail.present?
    row[:reply] = item.reply if item.kind == "comment_posted"
    row
  end
end
