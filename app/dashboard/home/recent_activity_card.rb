# frozen_string_literal: true

# "Recent activity" — a feed of recent assessment activity. For an IC, their
# own assessment's activity; for a manager, their direct reports'. Awareness,
# not action, so it sits below the actionable cards.
#
# Backed by {Assessments::RecentActivityQuery} (read-model only), never the
# per-assignment event-replay feed.
class Home::RecentActivityCard < Home::Card
  # High in the hierarchy — the activity feed is the main "what's happening"
  # surface. Sits just under the actionable "Awaiting you" (60), above the
  # oversight/progress cards (55/50).
  PRIORITY = 58
  LIMIT = 8

  def self.key = "recent_activity"

  def self.audience?(context)
    return false unless context.person

    Assessments::RecentActivityQuery.new(person_ids: scope_person_ids(context)).any?
  end

  # Registry only calls this for cards that passed `audience?`, so activity is
  # known to exist — emit the single instance.
  def self.instances(_context)
    [ build_instance(priority: PRIORITY, title: "Recent activity") ]
  end

  # IC → their own assessment activity; manager → their direct reports'.
  # @return [Array<String>]
  def self.scope_person_ids(context)
    person = context.person
    return [] unless person

    person.direct_reports.pluck(:id).presence || [ person.id ]
  end

  def render_content(_instance_key)
    scope = self.class.scope_person_ids(context)
    Views::Home::Cards::RecentActivity.new(
      items: Assessments::RecentActivityQuery.new(person_ids: scope, limit: LIMIT).call,
      team: scope != [ person&.id ]
    )
  end
end
