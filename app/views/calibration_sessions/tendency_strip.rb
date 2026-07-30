# frozen_string_literal: true

# The rater tendency strip — one row per participant: report/rated
# counts, mean at-level rating vs the org mean, the rating distribution
# (frequency palette segments), the self-gap, and evidence backing.
# The "acknowledge our biases first" surface; aggregates only, never
# individual self-ratings (docs/architecture/calibration-sessions.md).
#
# Small-n honesty: raters below the small-n floor show their numbers
# but never the amber deviation badges — two data points always look
# extreme.
class Views::CalibrationSessions::TendencyStrip < Views::Base
  include Views::Assessments::FrequencyPalette

  DEVIATION_THRESHOLD = 0.5

  # @param raters [Array<Hash>] OverviewStats rater rows
  # @param org_mean [Float, nil]
  # @param people [Hash{String => Person}]
  def initialize(raters:, org_mean:, people:)
    @raters = raters
    @org_mean = org_mean
    @people = people
  end

  def view_template
    render Components::Kit::Card.new do |card|
      card.body do
        h2(class: "text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
          "Rater tendency"
        end
        p(class: "mt-1 text-xs text-gray-600 dark:text-gray-300") do
          plain "At-level manager ratings, 0–3 scale."
          plain " Org mean #{sprintf('%.2f', @org_mean)}." if @org_mean
        end

        if @raters.all? { |r| r[:cell_count].zero? }
          p(class: "mt-4 text-sm text-gray-600 dark:text-gray-300") do
            "No at-level manager ratings yet — the strip fills in as raters rate."
          end
        else
          strip_table
        end
      end
    end
  end

  private

  def strip_table
    div(class: "mt-3 overflow-x-auto") do
      table(class: "w-full text-sm") do
        thead do
          tr(class: "text-left text-xs text-gray-600 dark:text-gray-300") do
            th(class: "py-1.5 pr-3 font-medium") { "Rater" }
            th(class: "py-1.5 pr-3 font-medium") { "Reports" }
            th(class: "py-1.5 pr-3 font-medium") { "vs org mean" }
            th(class: "py-1.5 pr-3 font-medium") { "Distribution" }
            th(class: "py-1.5 pr-3 font-medium") { "Self-gap" }
            th(class: "py-1.5 pr-3 font-medium") { "Evidence" }
            th(class: "py-1.5 font-medium") { "Carried" }
          end
        end
        tbody do
          @raters.each { |rater| rater_row(rater) }
        end
      end
    end
  end

  def rater_row(rater)
    tr(class: "border-t border-gray-100 dark:border-gray-800") do
      td(class: "py-2 pr-3 font-medium text-gray-900 dark:text-white whitespace-nowrap") do
        plain @people[rater[:participant_id]]&.name || "Unknown"
      end
      td(class: "py-2 pr-3 text-gray-600 dark:text-gray-300 whitespace-nowrap") do
        plain "#{rater[:report_count]} · #{rater[:cell_count]} cells"
      end
      td(class: "py-2 pr-3 whitespace-nowrap") { org_delta_cell(rater) }
      td(class: "py-2 pr-3") { distribution_bar(rater) }
      td(class: "py-2 pr-3 whitespace-nowrap") { self_gap_cell(rater) }
      td(class: "py-2 pr-3 whitespace-nowrap text-gray-600 dark:text-gray-300") do
        plain rater[:evidence_pct] ? "#{(rater[:evidence_pct] * 100).round}%" : "—"
      end
      td(class: "py-2 whitespace-nowrap") { carried_cell(rater) }
    end
  end

  # How much of this rater's row they actually decided THIS cycle. An
  # all-carried row is last cycle's tendency, unexamined — which is why it
  # also suppresses the ▲/▼/⚠ emphasis below.
  def carried_cell(rater)
    carried = rater[:carried_count].to_i
    return span(class: "text-gray-600 dark:text-gray-300") { "—" } if carried.zero?

    span(
      class: "text-amber-700 dark:text-amber-300#{' font-medium' if all_carried?(rater)}",
      title: "#{carried} of #{rater[:cell_count]} ratings carried forward from the previous " \
             "cycle and not confirmed this one"
    ) { all_carried?(rater) ? "all #{carried}" : "#{carried} of #{rater[:cell_count]}" }
  end

  # Every rated cell carried — nothing in this row was decided this cycle.
  def all_carried?(rater)
    rater[:cell_count].to_i.positive? && rater[:carried_count].to_i == rater[:cell_count]
  end

  def org_delta_cell(rater)
    delta = rater[:org_delta]
    return span(class: "text-gray-600 dark:text-gray-300") { "—" } unless delta

    # Not "notable" when the whole row is carried: calling a rater lenient
    # on numbers they never confirmed this cycle is the wrong conversation.
    notable = delta.abs >= DEVIATION_THRESHOLD && !rater[:small_n] && !all_carried?(rater)
    span(class: notable ? "text-amber-700 dark:text-amber-300 font-medium" : "text-gray-900 dark:text-white") do
      plain signed(delta)
      plain delta.positive? ? " ▲" : (delta.negative? ? " ▼" : "")
    end
  end

  def self_gap_cell(rater)
    gap = rater[:self_gap]
    return span(class: "text-gray-600 dark:text-gray-300") { "—" } unless gap

    notable = gap <= -DEVIATION_THRESHOLD && !rater[:small_n] && !all_carried?(rater)
    span(class: notable ? "text-amber-700 dark:text-amber-300 font-medium" : "text-gray-900 dark:text-white") do
      plain signed(gap)
      plain " ⚠" if notable
    end
  end

  # Segmented bar in the shared frequency palette, with a text
  # equivalent for AT (1.4.1 — never colour alone).
  def distribution_bar(rater)
    counts = rater[:distribution]
    total = counts.values.sum
    return span(class: "text-gray-600 dark:text-gray-300") { "—" } if total.zero?

    summary = CONFIG.map { |freq, config| "#{config[:label]} #{counts[freq]}" }.join(", ")
    div(class: "flex items-center gap-2") do
      div(class: "flex h-2.5 w-28 overflow-hidden rounded-full bg-gray-100 dark:bg-gray-800",
          role: "img", aria: { label: "Rating distribution: #{summary}" }, title: summary) do
        CONFIG.each do |freq, config|
          next if counts[freq].zero?

          div(class: "h-2.5 #{config[:dot]}", style: "width: #{(counts[freq].to_f / total * 100).round(1)}%")
        end
      end
      span(class: "text-xs text-gray-600 dark:text-gray-300", aria: { hidden: "true" }) { summary }
    end
  end

  def signed(value)
    sprintf("%+.2f", value).sub("-", "−")
  end
end
