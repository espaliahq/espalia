# frozen_string_literal: true

# The scenarios removed from a plan, under its scenario tree and closed until
# opened ([#340](https://github.com/espaliahq/espalia/issues/340)): one line
# each, newest first. Absent when nothing has been removed. Read-only, so an
# archived or frozen plan shows it the same.
class Views::Plans::RemovedScenarios < Views::Base
  # @param plan_id [String]
  # @param read [Hash] from `team_planning_removed_scenarios`
  # @param open [Boolean] whether it renders open, as when paging through it
  def initialize(plan_id:, read:, open: false)
    @plan_id = plan_id
    @read = read
    @open = open
  end

  def view_template
    return if @read[:total].zero?

    details(id: "removed-scenarios", open: @open, data: { removed_scenarios: "" }, class: "mt-4 text-sm") do
      summary(class: "text-default font-medium") { "Removed scenarios (#{@read[:total]})" }
      ul(class: "mt-2 divide-y divide-subtle") { @read[:removed].each { entry(it) } }
      pager
    end
  end

  private

  def entry(row)
    li(data: { removed_scenario: row[:scenario_id] }, class: "py-1.5 text-muted") do
      span(class: "text-default") { row[:name] || "A scenario whose name is gone" }
      plain " · "
      period(row)
      plain " · #{row[:changes]} #{'change'.pluralize(row[:changes])} · removed by #{row[:removed_by][:name]} on "
      day(row[:removed_at])
    end
  end

  def period(row)
    plain "from " unless row[:ends_on]
    day(row[:starts_on])
    return unless row[:ends_on]

    plain " – "
    day(row[:ends_on])
  end

  def pager
    page = @read[:page]
    return unless page > 1 || @read[:next_page]

    div(class: "mt-2 flex gap-4") do
      link("Newer", page - 1) if page > 1
      link("Older", page + 1) if @read[:next_page]
    end
  end

  def link(label, page)
    render Components::Kit::Button.new(variant: :link, tone: :brand, compact: true,
                                       href: plan_path(@plan_id, removed_page: page, anchor: "removed-scenarios")) { label }
  end

  def day(iso) = span(class: "whitespace-nowrap") { Date.iso8601(iso.to_s[0, 10]).strftime("%-d %b %Y") }
end
