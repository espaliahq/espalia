# frozen_string_literal: true

# Readiness as cell coverage — how much of the population's rating work is
# done, and by whom (docs/architecture/calibration-sessions.md, "Readiness").
#
# Three shares on ONE denominator, the population's at-level cells: rated
# (confirmed this cycle + carried from the last), carried, and evidence-backed.
# One rating moves every number here, which the old "N of M people fully
# rated" bar never did — a rater could fill nine of twelve cells and leave it
# exactly where it was, and the room read the page as frozen.
#
# The per-rater table says what each rater has left in one word ("Ready", "N
# to confirm", "N unrated"). It is open in draft, where readiness is the
# question, and collapsed once live, where the tendency strip is.
class Views::CalibrationSessions::ReadinessCard < Views::Base
  include Views::CalibrationSessions::Glossary
  include Views::CalibrationSessions::RaterColours
  include Views::CalibrationSessions::PeopleNames

  # The dashed carried vocabulary as a bar segment: amber stripes, so a
  # carried share never reads as a confirmed one in greyscale either.
  CARRIED_SEGMENT = "bg-[repeating-linear-gradient(135deg,var(--color-amber-500)_0_3px,transparent_3px_6px)]"
  CONFIRMED_SEGMENT = "bg-primary"
  EVIDENCE_SEGMENT = "bg-gray-600 dark:bg-gray-300"
  TRACK = "relative flex overflow-hidden rounded-full bg-gray-100 dark:bg-gray-800"

  # @param readiness [Hash, nil] OverviewStats `readiness` (nil: nobody to measure)
  # @param raters [Array<Hash>] OverviewStats rater rows
  # @param people [Hash{String => Person}]
  # @param people_total [Integer] the population size
  # @param fully_rated_count [Integer] people whose manager side is complete and vetted
  # @param unenrolled_count [Integer] population members not enrolled in the cycle
  # @param open [Boolean] whether the per-rater table starts expanded
  def initialize(readiness:, raters:, people:, people_total:, fully_rated_count:,
                 unenrolled_count:, open:)
    @readiness = readiness
    @raters = raters
    @people = people
    @people_total = people_total
    @fully_rated_count = fully_rated_count
    @unenrolled_count = unenrolled_count
    @open = open
  end

  def view_template
    section(
      id: "calibration-readiness",
      class: "mt-4 rounded-md border border-gray-200 dark:border-gray-700 px-4 py-3",
      aria: { labelledby: "calibration-readiness-heading" },
      # Read by calibration_freshness_controller for the "Readiness 76% → 78%"
      # line of the update toast.
      data: { readiness_coverage: percent(@readiness&.dig(:coverage_pct)) }
    ) do
      summary_line
      if @readiness && @readiness[:cell_total].positive?
        population_bar
        legend
        rater_table if @raters.any? || @readiness[:reference].any?
      end
    end
  end

  private

  def summary_line
    div(class: "flex flex-wrap items-center gap-x-4 gap-y-1 text-sm") do
      h2(id: "calibration-readiness-heading",
         class: "text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") { "Readiness" }

      if @readiness.nil? || @readiness[:cell_total].zero?
        span(class: "text-gray-600 dark:text-gray-300") { "No at-level cells to rate yet." }
      else
        rated = percent(@readiness[:coverage_pct])
        span(class: "text-gray-900 dark:text-white") do
          defined_term(:rating_coverage, label: "#{rated}% rated", suffix: "summary")
          span(class: "text-gray-600 dark:text-gray-300") do
            plain " · #{percent(@readiness[:carried_pct])}% carried · #{100 - rated}% unrated"
          end
        end
        span(class: "text-gray-600 dark:text-gray-300") do
          defined_term(:evidence_coverage,
                       label: "Evidence on #{percent(@readiness[:evidence_coverage_pct])}%",
                       suffix: "summary")
        end
      end

      span(class: "text-gray-600 dark:text-gray-300") do
        defined_term(:fully_rated, label: "#{@fully_rated_count} of #{@people_total} people fully rated")
      end
      if @unenrolled_count.positive?
        span(class: "text-amber-700 dark:text-amber-300") { "#{@unenrolled_count} not enrolled in the cycle" }
      end
    end
  end

  def population_bar
    stacked_bar(@readiness, height: "h-2.5", label: "Population")
  end

  def legend
    div(class: "mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-gray-600 dark:text-gray-300") do
      legend_swatch(CONFIRMED_SEGMENT, "Confirmed this cycle")
      legend_swatch("#{CARRIED_SEGMENT} border border-dashed border-amber-500", "Carried from last cycle, not yet confirmed")
      legend_swatch("bg-gray-100 dark:bg-gray-800 border border-gray-300 dark:border-gray-600", "Unrated")
      span { "All shares of the same thing: the population's at-level cells." }
    end
  end

  def legend_swatch(classes, label)
    span(class: "inline-flex items-center gap-1.5") do
      span(class: "inline-block h-2.5 w-2.5 rounded-sm #{classes}", aria: { hidden: "true" })
      plain label
    end
  end

  def rater_table
    details(
      class: "mt-3 group",
      open: @open,
      data: { readiness_raters: "true" }
    ) do
      summary(class: "inline-flex min-h-11 cursor-pointer items-center gap-1 text-sm font-medium " \
                     "text-primary-ink hover:underline") do
        span(class: "group-open:hidden") { "Show raters (#{rater_row_count})" }
        span(class: "hidden group-open:inline") { "Hide raters" }
      end
      div(class: "mt-2 overflow-x-auto") do
        table(class: "w-full text-sm") do
          thead do
            tr(class: "text-left text-xs text-gray-600 dark:text-gray-300") do
              th(class: "py-1.5 pr-3 font-medium") { "Rater" }
              th(class: "py-1.5 pr-3 font-medium") { defined_term(:reports) }
              th(class: "py-1.5 pr-3 font-medium min-w-48") do
                defined_term(:rating_coverage)
                plain " "
                defined_term(:carried, label: "(% carried)")
              end
              th(class: "py-1.5 pr-3 font-medium min-w-36") { defined_term(:evidence_coverage) }
              th(class: "py-1.5 font-medium text-right") { defined_term(:ready, align: :right) }
            end
          end
          tbody do
            @raters.each_with_index { |rater, index| rater_row(rater, index) }
            @readiness[:reference].each { |row| reference_row(row) }
          end
        end
      end
    end
  end

  def rater_row_count
    @raters.size + @readiness[:reference].size
  end

  def rater_row(rater, index)
    tr(class: "border-t border-gray-100 dark:border-gray-800", data: { readiness_rater: rater[:participant_id] }) do
      td(class: "py-2 pr-3 whitespace-nowrap font-medium text-gray-900 dark:text-white") do
        span(class: "mr-1.5 inline-block h-2.5 w-2.5 rounded-full align-middle #{rater_dot_class(index)}",
             aria: { hidden: "true" })
        plain person_name(rater[:participant_id])
      end
      reports_cell(rater[:report_count], rater[:cell_total])
      coverage_cells(rater)
      td(class: "py-2 whitespace-nowrap text-right") { ready_label(rater) }
    end
  end

  # Population members whose rater isn't in the room: their numbers count in
  # the totals above, but nobody here can act on them.
  def reference_row(row)
    tr(class: "border-t border-gray-100 dark:border-gray-800 opacity-70", data: { readiness_reference: "true" }) do
      td(class: "py-2 pr-3 whitespace-nowrap text-gray-600 dark:text-gray-300") do
        span(class: "mr-1.5 inline-block h-2.5 w-2.5 rounded-full align-middle bg-gray-400 dark:bg-gray-500",
             aria: { hidden: "true" })
        plain "Not in session "
        span(class: "text-xs") do
          rater = row[:rater_id] ? person_name(row[:rater_id]) : "no recorded manager"
          plain "(#{rater} · #{row[:person_count]} #{row[:person_count] == 1 ? 'person' : 'people'})"
        end
      end
      reports_cell(row[:person_count], row[:cell_total])
      coverage_cells(row)
      td(class: "py-2 whitespace-nowrap text-right text-xs text-gray-600 dark:text-gray-300") { "reference only" }
    end
  end

  def reports_cell(count, cells)
    td(class: "py-2 pr-3 whitespace-nowrap text-gray-900 dark:text-white") do
      plain count.to_s
      span(class: "text-gray-600 dark:text-gray-300") { " · #{cells} #{cells == 1 ? 'cell' : 'cells'}" }
    end
  end

  def coverage_cells(row)
    if row[:cell_total].zero?
      td(class: "py-2 pr-3 text-gray-600 dark:text-gray-300", colspan: 2) { "No at-level cells" }
      return
    end

    td(class: "py-2 pr-3") do
      div(class: "flex items-center gap-2") do
        span(class: "w-28 shrink-0 whitespace-nowrap") do
          span(class: "font-medium text-gray-900 dark:text-white") { "#{percent(row[:coverage_pct])}%" }
          span(class: "text-gray-600 dark:text-gray-300") { " · #{percent(row[:carried_pct])}% carried" }
        end
        stacked_bar(row, height: "h-1.5", label: "Rating coverage", extra: "min-w-16 flex-1")
      end
    end
    td(class: "py-2 pr-3") do
      div(class: "flex items-center gap-2") do
        evidence = percent(row[:evidence_coverage_pct])
        span(class: "w-10 shrink-0 font-medium text-gray-900 dark:text-white") { "#{evidence}%" }
        div(class: "#{TRACK} h-1.5 min-w-16 flex-1", role: "img",
            aria: { label: "Evidence coverage: #{evidence}% of #{row[:cell_total]} cells" }) do
          div(class: EVIDENCE_SEGMENT, style: "width: #{width(row[:evidence_cell_count], row[:cell_total])}%")
        end
      end
    end
  end

  # Confirmed, then carried, on a track whose remainder is the unrated share.
  def stacked_bar(row, height:, label:, extra: "w-full mt-2")
    total = row[:cell_total]
    carried = row[:carried_count]
    confirmed = row[:cell_count] - carried
    summary = "#{label}: #{confirmed} confirmed, #{carried} carried, " \
              "#{row[:unrated_count]} unrated of #{total} cells"

    div(class: "#{TRACK} #{height} #{extra}", role: "img", aria: { label: summary }, title: summary) do
      div(class: "#{height} #{CONFIRMED_SEGMENT}", style: "width: #{width(confirmed, total)}%") if confirmed.positive?
      div(class: "#{height} #{CARRIED_SEGMENT}", style: "width: #{width(carried, total)}%") if carried.positive?
    end
  end

  # The one word naming the work left (OverviewStats.ready_state).
  def ready_label(row)
    case row[:ready_state]
    when "ready"
      render Components::Kit::Badge.new("Ready", variant: :success)
    when "to_confirm"
      carried = row[:carried_count]
      label = carried == row[:cell_total] ? "All #{carried} to confirm" : "#{carried} to confirm"
      render Components::Kit::ToConfirmChip.new(
        label, title: "Every cell has a value; #{carried} were carried from the last cycle and not confirmed"
      )
    when "unrated"
      render Components::Kit::Badge.new("#{row[:unrated_count]} unrated", variant: :default)
    else
      span(class: "text-xs text-gray-600 dark:text-gray-300") { "No reports" }
    end
  end

  def percent(fraction)
    fraction ? (fraction * 100).round : 0
  end

  def width(part, total)
    total.zero? ? 0 : (part.to_f / total * 100).round(1)
  end
end
