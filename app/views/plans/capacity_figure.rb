# frozen_string_literal: true

# One place's capacity, a person's or an open position's, drawn the same way
# so the two compare. It opens to show its working: each step of the model,
# then the planner's override if there is one, and whether managing others
# costs the seat more than its base.
class Views::Plans::CapacityFigure < Views::Base
  Format = Views::Plans::CapacityMarks::Format

  # @param place [Hash] a place from `team_planning_capacity`
  # @param marks [Views::Plans::CapacityMarks]
  # @param label [String] whose capacity it is, for a screen reader
  def initialize(place:, marks:, label:)
    @place = place
    @marks = marks
    @label = label
  end

  def view_template
    details(data: { capacity_figure: "" }, class: "open:basis-full text-sm") do
      summary(class: "inline-flex items-center gap-1 rounded px-1 tabular-nums text-default hover:bg-subtle") do
        span(class: "sr-only") { "#{@label}:" }
        span(class: "underline decoration-dotted underline-offset-2") { headline }
        render Components::Kit::Badge.new("override", size: :sm) if @place[:overridden]
      end
      div(class: "mt-1 rounded border border-subtle bg-subtle px-3 py-2 text-muted") { working }
    end
  end

  private

  def capacity = @place[:capacity] && BigDecimal(@place[:capacity])

  def symbol = @marks.unit_of(@place[:model])

  def headline = capacity ? Format.amount(capacity, symbol) : "No capacity"

  def working
    unless capacity
      p { @place[:reason_text] || "No model covers this place." }
      calculated
      return
    end

    p(class: "text-xs") { @marks.description_of(@place[:model]) }
    ol(class: "mt-1 space-y-0.5") { @place[:working].each { step(it) } }
    calculated if @place[:overridden]
    overload(@place)
    notes(@place)
  end

  def step(step)
    li(class: "flex gap-2 tabular-nums") do
      span(class: "w-3 shrink-0 text-center", aria: { hidden: "true" }) { step[:op] }
      span(class: "min-w-0 flex-1 break-words") { step_label(step) }
      span(class: "shrink-0 text-default") { Format.step(BigDecimal(step[:amount])) }
    end
  end

  def step_label(step)
    return step[:label] unless step[:subject_id]

    "#{step[:label]}: #{@marks.subject_names.fetch(step[:subject_id], 'an open position')}"
  end

  def calculated
    return unless @place[:calculated]

    p(class: "mt-1") { "The model gives #{Format.amount(BigDecimal(@place[:calculated]), symbol)}." }
    return unless (model = @place[:calculated_diagnostics])

    overload(model)
    notes(model)
  end

  def overload(figure)
    return unless figure[:overloaded]

    p(class: "mt-1 text-default", data: { capacity_overloaded: "" }) do
      "Overloaded: managing others costs #{Format.amount(BigDecimal(figure[:excess]), symbol)} more than this seat's base."
    end
  end

  def notes(figure)
    texts = figure[:notes].map { it[:text] }.compact
    ul(class: "mt-1 list-disc pl-5") { texts.each { |text| li { text } } } if texts.any?
  end
end
