# frozen_string_literal: true

# One unit's activity feed (#137), the read behind the Units view's sidebar,
# or with no unit the organisation's own: who was made an Org Graph editor,
# and who stopped being one. The organisation's feed is for admins and
# editors. People are named through {Person}, so a forgotten person reads as
# a former member.
class Operations::OrgGraph::Activity < Operations::Base
  description "Read one Org Graph unit's activity, newest first, 25 groups a page. Leave out unit_id to " \
              "read the organisation's own activity instead: who was made an Org Graph editor, and who " \
              "stopped being one. These can't be changed back here. A group is every " \
              "change made under one cause, such as one request or one approved plan change. Each " \
              "group has its summary, who made it (a person's name, or the provider that supplied it), " \
              "when it took effect, when the Org Graph learned it, any plan reference, its parts and " \
              "whether the caller can change it back, with the reason when not. Each part has its own " \
              "id, description and change-back answer. Changing a group back reverses it in every unit " \
              "it touched, and units_touched counts them. Only an admin or an Org Graph editor can change " \
              "anything back. A unit's activity is for anyone org_graph_units admits, whichever unit it is; " \
              "the organisation's is for admins and Org Graph editors."
  category :read
  approval :none

  parameter :unit_id, String, required: false, allow_blank: false, schema: { format: "uuid" }
  parameter :page, Integer, required: false

  def policy_check
    authorize :org_graph, params[:unit_id].nil? ? :edit_structure? : :show_units?
  end

  # @return [Hash] `:unit_id` (nil for the organisation), `:page`, `:next_page` and `:groups`
  # @raise [Operations::Base::ParameterError] for a unit the Org Graph doesn't hold
  def perform
    feed = ::OrgGraph::ActivityFeed.new(unit:, actor: context, page: params[:page] || 1)

    { unit_id: feed.unit&.id, page: feed.page, next_page: feed.next_page?, groups: feed.items.map { group_payload(it) } }
  end

  private

  def unit
    return if params[:unit_id].nil?

    OrgUnit.find_by(id: params[:unit_id].to_s.downcase) or raise ParameterError, "unit_id names no unit in the Org Graph"
  end

  def group_payload(item)
    group = item.group
    {
      cause_id: group.cause_id,
      summary: item.headline,
      by: item.parts.first.by,
      effective_on: group.latest.effective_on&.iso8601,
      learned_at: group.learned_at.iso8601,
      plan_id: group.plan_id,
      plan_change_id: group.plan_change_id,
      changed_back: group.changed_back?,
      units_touched: item.unit_count,
      can_change_back: item.changeable?,
      cannot_change_back_because: item.refusal,
      parts: item.parts.map { part_payload(it) }
    }
  end

  def part_payload(part)
    entry = part.entry
    {
      id: entry.id,
      event_type: entry.event_type,
      description: part.description,
      by: part.by,
      person_id: entry.person_id,
      person_name: entry.person_id && (entry.person&.name || Person::FORMER_MEMBER),
      effective_on: entry.effective_on&.iso8601,
      learned_at: entry.learned_at.iso8601,
      changed_back: entry.changed_back?,
      can_change_back: part.changeable?,
      cannot_change_back_because: part.refusal
    }
  end
end
