# frozen_string_literal: true

# The scenario's capacity, per model, above the map: each total beside
# Today's, what counts in no unit on the map, and the places that count for
# none ([#296](https://github.com/espaliahq/espalia/issues/296)).
class Views::Plans::CapacityStrip < Views::Base
  Format = Views::Plans::CapacityMarks::Format

  # @param marks [Views::Plans::CapacityMarks]
  def initialize(marks:)
    @marks = marks
  end

  def view_template
    section(aria: { labelledby: "capacity-strip" }, data: { capacity_strip: "" },
            class: "rounded-lg border border-default bg-default px-4 py-3 space-y-2") do
      div(class: "flex flex-wrap items-baseline gap-x-6 gap-y-2") do
        h3(id: "capacity-strip", class: "text-sm font-semibold text-default") { "Capacity" }
        @marks.totals.each { total(it) }
      end
      @marks.totals.each do |total|
        p(class: "text-xs text-muted") { "#{total.unit}: #{@marks.description_of(total.model).downcase_first}." }
      end
      p(class: "text-sm text-muted") { compared_with }
      outside_units
      unclassified
    end
  end

  private

  def total(total)
    div(data: { capacity_total: total.model }, class: "flex flex-wrap items-baseline gap-x-2") do
      span(class: "text-lg font-semibold tabular-nums text-default") { Format.amount(total.amount, total.unit) }
      change(total) unless @marks.baseline?
    end
  end

  def change(total)
    text = Format.change(total.change, total.unit)
    span(data: { capacity_change: total.model }, class: "text-sm tabular-nums #{text ? 'text-default' : 'text-muted'}") do
      text ? "#{text} vs Today" : "same as Today"
    end
  end

  def compared_with
    if @marks.baseline?
      "This is Today, which every scenario's capacity is compared with."
    else
      "Each change is measured against Today, as cost is, not against the scenario this one follows."
    end
  end

  def outside_units
    rest = @marks.outside_units
    return if rest.empty?

    p(data: { capacity_outside: "" }, class: "text-sm text-muted") do
      plain "Of these, #{rest.map { Format.amount(it.amount, it.unit) }.to_sentence} "
      plain "counts in no unit on the map: someone in no unit, or a place in a unit gone by this date."
    end
  end

  def unclassified
    places = @marks.unclassified
    return if places.empty?

    details(data: { capacity_unclassified: "" }, class: "text-sm") do
      summary(class: "text-default underline") do
        "#{places.size} #{places.size == 1 ? 'place counts' : 'places count'} for no capacity"
      end
      ul(class: "mt-1 list-disc pl-5 text-muted") do
        places.each { |place| li { "#{@marks.seat_name(place[:seat_id], place[:kind])}: #{place[:reason_text].downcase_first}" } }
      end
    end
  end
end
