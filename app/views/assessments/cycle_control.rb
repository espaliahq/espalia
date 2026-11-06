# frozen_string_literal: true

# The header's cycle switcher: every cycle the person joined on this
# framework, newest first. The open cycle is the page as it always was; a
# past one reloads the same page read-only with `?cycle_id=`
# (https://github.com/mr-yum/growth-os/issues/669). Every entry is a plain
# link, so a past cycle survives refresh, Back and sharing.
#
# Shown only when there is somewhere else to go: a cycle other than the one
# read, which includes a person whose only cycle has closed.
class Views::Assessments::CycleControl < Views::Base
  ID = "assessment-cycle-control"
  ITEM = Views::Assessments::LensControl::ITEM

  # @param lens [Assessments::Lens] the lens the page is read through
  # @param cycles [Array<Assessments::CycleHistory::Entry>] newest first
  # @param assessment_id [String]
  def initialize(lens:, cycles:, assessment_id:)
    @lens = lens
    @cycles = cycles
    @assessment_id = assessment_id
  end

  def view_template
    return if @cycles.none? { |entry| entry.cycle.cycle_id != @lens.cycle&.cycle_id }

    div(id: ID, class: "inline-block") do
      render Components::Kit::Dropdown.new(align: :left) do |dropdown|
        dropdown.trigger(label: "Cycle: #{current_name} — choose a cycle") do
          span(class: "inline-flex min-h-6 items-center gap-1 rounded px-1.5 py-0.5 text-xs font-medium " \
                      "cursor-pointer bg-neutral-subtle text-muted", data: { cycle: @lens.past? ? "past" : "open" }) do
            plain current_name
            span(class: "text-[10px] leading-none", aria_hidden: "true") { "▾" }
          end
        end
        # Narrow enough to open from mid-header on a phone; a long name wraps.
        dropdown.menu(width: "w-60") do
          @cycles.each { |entry| item(entry) }
        end
      end
    end
  end

  private

  def item(entry)
    current = entry.cycle.cycle_id == @lens.cycle&.cycle_id
    a(href: href_for(entry), role: "menuitem", class: "#{ITEM} #{current ? 'font-semibold' : ''}",
      aria: { current: (current ? "page" : nil) }.compact) do
      span(class: "w-4 shrink-0 self-start text-muted", aria_hidden: "true") { current ? "✓" : "" }
      span(class: "min-w-0 flex flex-col") do
        span(class: "break-words") { entry.cycle.name }
        span(class: "text-xs font-normal text-muted") { status_note(entry) }
      end
    end
  end

  def href_for(entry)
    return assessment_path(@assessment_id) if open?(entry)

    assessment_path(@assessment_id, cycle_id: entry.cycle.cycle_id)
  end

  # @return [String] e.g. "Open", "Closed 30 Jun", "Left"
  def status_note(entry)
    return "Open" if open?(entry)
    return "Left" if entry.enrollment.status == "withdrawn"

    closed_at = entry.cycle.closed_at
    closed_at ? "Closed #{closed_at.strftime('%-d %b %Y')}" : "Closed"
  end

  def open?(entry)
    entry.cycle.cycle_id == @lens.open_cycle_id
  end

  def current_name
    @lens.cycle&.name || "No open cycle"
  end
end
