# frozen_string_literal: true

# Content for the "Recent activity" card — a feed of recent assessment activity
# rendered as short sentences (actor-led, capability as a link, comment text
# inline) so it reads as a summary rather than a flat list. Read-only awareness.
class Views::Home::Cards::RecentActivity < Views::Base
  DOT_COLOR = {
    "self_rated" => "bg-activity-self",
    "manager_rated" => "bg-activity-manager",
    "assessment_aligned" => "bg-activity-attention",
    "evidence_recorded" => "bg-activity-attention",
    "comment_posted" => "bg-activity-discussion",
    "alignment_started" => "bg-activity-attention",
    "alignment_completed" => "bg-activity-complete"
  }.freeze

  SNIPPET_LIMIT = 90

  # @param items [Array<Assessments::RecentActivityQuery::Item>]
  # @param team [Boolean] true when showing reports' activity (vs. the viewer's own)
  def initialize(items:, team:)
    @items = items
    @team = team
  end

  def view_template
    render Components::Kit::Card.new(title: title, heading_level: :h2) do |card|
      card.body do
        if @items.empty?
          p(class: "text-sm text-muted") { "No recent activity." }
        else
          ul(class: "space-y-3") { @items.each { |item| activity_row(item) } }
        end
      end
    end
  end

  private

  def title = @team ? "Recent activity · your team" : "Recent activity"

  def activity_row(item)
    li(class: "flex items-start gap-2") do
      span(class: "mt-1.5 h-2 w-2 shrink-0 rounded-full #{DOT_COLOR.fetch(item.kind, "bg-activity-cleared")}")
      div(class: "min-w-0 flex-1") do
        p(class: "text-sm text-muted") { sentence(item) }
        p(class: "mt-0.5 text-xs text-muted") { local_time_ago(item.occurred_at) }
      end
    end
  end

  # Builds the activity sentence inline (actor leads; the capability is a link).
  def sentence(item)
    actor = actor_name(item)
    assessee_clause = item.actor_other? ? "#{item.person_name}'s " : ""

    case item.kind
    when "self_rated"
      phrase(actor, " self-rated ", cap_link(item))
    when "manager_rated"
      phrase(actor, " rated ", rated_object(item))
    when "assessment_aligned"
      phrase(actor, " aligned ", assessee_clause, cap_link(item))
    when "evidence_recorded"
      phrase(actor, " added feedback to ", assessee_clause, cap_link(item))
    when "comment_posted"
      comment_sentence(item, actor, assessee_clause)
    when "alignment_started"
      phrase(actor, " started alignment", alignment_for(item))
    when "alignment_completed"
      phrase(actor, " completed alignment", alignment_for(item))
    else
      phrase(actor, " — ", cap_link(item))
    end
  end

  # Emits a sequence of strings / rendered nodes, bolding the leading actor.
  def phrase(actor, *parts)
    strong(class: "font-medium text-default") { actor }
    parts.each { |part| part.respond_to?(:call) ? part.call : plain(part.to_s) }
  end

  def rated_object(item)
    lambda do
      plain "#{item.person_name} on "
      render_cap_link(item)
    end
  end

  def comment_sentence(item, actor, assessee_clause)
    verb = item.reply ? " replied on " : " commented on "
    phrase(actor, verb, -> { plain("#{assessee_clause}"); render_cap_link(item) }, snippet(item))
  end

  def alignment_for(item)
    return "" unless @team && item.actor_other?

    " for #{item.person_name}"
  end

  def snippet(item)
    return "" if item.detail.blank?

    lambda do
      span(class: "text-muted") { ": " }
      span { "“#{item.detail.to_s.truncate(SNIPPET_LIMIT)}”" }
    end
  end

  # The capability name as a link into the assessment cell.
  def cap_link(item) = -> { render_cap_link(item) }

  def render_cap_link(item)
    label = cell_label(item)
    return plain(label) unless item.assignment_id

    a(href: item_path(item), data: { turbo_frame: "_top" },
      class: "font-medium text-brand hover:underline") { label }
  end

  def cell_label(item)
    [ item.capability_name || "an assessment", item.level_ordinal && "L#{item.level_ordinal}" ]
      .compact.join(" ")
  end

  def actor_name(item)
    return item.actor_name if item.actor_name.present?

    item.kind == "manager_rated" ? "A manager" : item.person_name
  end

  def item_path(item)
    params = {}
    params[:capability] = item.capability_stable_id if item.capability_stable_id
    params[:level_ordinal] = item.level_ordinal if item.level_ordinal
    assessment_path(item.assignment_id, **params)
  end
end
