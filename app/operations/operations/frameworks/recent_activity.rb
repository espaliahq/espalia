# frozen_string_literal: true

# Recent activity for one framework — the suggestion lifecycle, draft/version
# lifecycle, structural and editorial edits, and collaborator changes, most-
# recent first. The MCP read-parity twin of the explorer's context-pane feed,
# backed by the same {Frameworks::ActivityFeedQuery}. Read-only; emits event
# metadata (kind, who, which capability/category, when) but never the full
# proposed text bodies — drill into a capability or suggestion for those.
class Operations::Frameworks::RecentActivity < Operations::Base
  description "Recent framework activity (suggestions, draft/version lifecycle, structural and " \
              "editorial edits, collaborator changes) — metadata only, most-recent first."
  category :read
  approval :none

  DEFAULT_LIMIT = 20
  MAX_LIMIT = 100

  parameter :framework_id, String, required: true
  parameter :limit, Integer, required: false

  def policy_check
    authorize framework, :view_suggestions?
  end

  def perform
    entries = Frameworks::ActivityFeedQuery.new(framework: framework).call.first(limit)

    { framework_id: params[:framework_id], activity: entries.map { |entry| serialize(entry) } }
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  def limit
    requested = params[:limit].to_i
    requested.positive? ? [ requested, MAX_LIMIT ].min : DEFAULT_LIMIT
  end

  def serialize(entry)
    {
      kind: entry.kind,
      occurred_at: entry.occurred_at&.iso8601,
      actor: entry.actor_name ? { name: entry.actor_name } : nil,
      capability: entry.capability_id ? { id: entry.capability_id, name: entry.capability_name } : nil,
      category_id: entry.category_id
    }.compact
  end
end
