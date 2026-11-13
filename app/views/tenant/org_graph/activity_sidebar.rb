# frozen_string_literal: true

# The opened unit's activity (#137), in the Units view's sidebar: a group per
# cause, newest first, saying who made it, what it did, when it took effect
# and when the Org Graph learned it. A group of several parts opens to show
# them. "Change it back" appears where the reader may, and the reason where
# they may not.
class Views::Tenant::OrgGraph::ActivitySidebar < Views::Base
  include Phlex::Rails::Helpers::Routes

  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  # @param feed [OrgGraph::ActivityFeed]
  def initialize(feed:)
    @feed = feed
  end

  def view_template
    render Views::Tenant::OrgGraph::Sidebar.new(title: "Activity") do
      if @feed.items.empty?
        render Components::Kit::EmptyState.new(title: "No activity yet", size: :panel) do
          "Changes to #{@feed.unit.name} appear here as the Org Graph learns of them."
        end
      else
        ol(class: "divide-y divide-subtle", aria: { label: "Activity in #{@feed.unit.name}, newest first" }) do
          @feed.items.each { |item| group_row(item) }
        end
      end
      pages
    end
  end

  private

  def group_row(item)
    group = item.group
    li(id: "activity-#{group.cause_id.parameterize}", class: "py-3 first:pt-0 last:pb-0") do
      div(class: "flex flex-wrap items-baseline gap-x-2 gap-y-1") do
        p(class: "text-sm font-medium text-default") { item.headline }
        render Components::Kit::Badge.new("Changed back", tone: :neutral) if group.changed_back?
      end
      when_line(item.parts.first)
      plan_reference(group)
      parts(item) if item.parts.many?
      change_back(item)
    end
  end

  def when_line(part, css: "mt-0.5")
    entry = part.entry
    p(class: "#{css} text-xs text-muted") do
      plain "#{part.by} · "
      if entry.effective_on
        plain "took effect "
        time(datetime: entry.effective_on.iso8601) { day(entry.effective_on) }
        plain ", "
      end
      plain "learned "
      time(datetime: entry.learned_at.iso8601) { "#{day(entry.learned_at)} at #{entry.learned_at.strftime('%H:%M')}" }
    end
  end

  def plan_reference(group)
    return unless group.plan_id

    p(class: "mt-0.5 text-xs text-muted") do
      plain "From plan "
      reference_id(group.plan_id)
      if group.plan_change_id
        plain ", change "
        reference_id(group.plan_change_id)
      end
    end
  end

  # A UUID v7 starts with its timestamp, which plans made in the same minute
  # share, so a shortened one shows its random tail.
  def reference_id(id)
    short = id.match?(UUID) ? "…#{id.last(8)}" : id
    code(class: "font-mono", title: id) { short }
  end

  def parts(item)
    details(class: "mt-2") do
      summary(class: "text-xs text-link hover:text-link-hover") { "Show #{item.parts.size} parts" }
      ul(class: "mt-2 space-y-2 border-l border-subtle pl-3") do
        item.parts.each do |part|
          li(id: "activity-entry-#{part.entry.id}") do
            p(class: "text-sm text-default") { part.description }
            when_line(part, css: "")
            entry_change_back(part)
          end
        end
      end
    end
  end

  def change_back(item)
    return if item.group.changed_back?

    if item.changeable?
      if item.whole_cause?
        change_back_form("Change it all back", cause_id: item.group.cause_id)
      else
        change_back_form("Change it back", entry_id: item.parts.first.entry.id)
      end
      if item.unit_count > 1
        p(class: "mt-1 text-xs text-muted") { "This changes it back in all #{item.unit_count} units it touched." }
      end
    else
      refusal(item.refusal)
    end
  end

  def entry_change_back(part)
    return if part.entry.changed_back?

    part.changeable? ? change_back_form("Change this back", entry_id: part.entry.id) : refusal(part.refusal)
  end

  def change_back_form(label, entry_id: nil, cause_id: nil)
    form(action: change_back_tenant_org_graph_path, method: "post", class: "mt-1") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "unit", value: @feed.unit.id)
      if entry_id
        input(type: "hidden", name: "entry_id", value: entry_id)
      else
        input(type: "hidden", name: "cause_id", value: cause_id)
      end
      render Components::Kit::Button.new(variant: :link, tone: :brand, size: :sm, compact: true, type: :submit) { label }
    end
  end

  def refusal(reason)
    p(class: "mt-1 text-xs text-muted") { "Can't change back: #{reason.delete_suffix('.')}" }
  end

  def pages
    return unless @feed.page > 1 || @feed.next_page?

    nav(class: "mt-4 flex justify-between text-sm", aria: { label: "Activity pages" }) do
      page_link("Newer", @feed.page - 1) if @feed.page > 1
      page_link("Older", @feed.page + 1, css: "ml-auto") if @feed.next_page?
    end
  end

  def page_link(label, page, css: "")
    a(href: tenant_org_graph_path(unit: @feed.unit.id, activity_page: page),
      class: "#{css} text-link hover:text-link-hover underline") { label }
  end

  def day(date) = date.year == Date.current.year ? date.strftime("%-d %b") : date.strftime("%-d %b %Y")
end
