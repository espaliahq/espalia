# frozen_string_literal: true

# What a closed step planned beside what happened, unit by unit
# ([#466](https://github.com/espaliahq/espalia/issues/466)), from
# `team_planning_step_outcome`. The dialog draws it first as a placeholder
# frame, which loads once opened. A table on a wide screen, a card per unit
# on a phone. Heads and names only.
class Views::Plans::StepOutcome < Views::Base
  LOADING = "Loading the outcome…"

  OUTCOMES = {
    "planned_not_here" => "Planned here but isn't",
    "here_not_planned" => "Here but not planned",
    "hire_not_filled" => "Hire not filled",
    "as_planned" => "As planned"
  }.freeze

  # @param scenario_id [String]
  # @param outcome [Hash, nil] from `team_planning_step_outcome`; nil for the placeholder
  # @param refusal [String, nil] why the outcome can't be read, in the operation's words
  # @param src [String, nil] the frame's own path, for the placeholder
  def initialize(scenario_id:, outcome: nil, refusal: nil, src: nil)
    @scenario_id = scenario_id
    @outcome = outcome
    @refusal = refusal
    @src = src
  end

  # @return [String] the frame's DOM id
  def self.frame_id(scenario_id) = "step-outcome-frame-#{scenario_id}"

  def view_template
    turbo_frame_tag(self.class.frame_id(@scenario_id), src: @src, loading: ("lazy" if @src), class: "block",
                                                         data: { frame_error_target: "frame" }) do
      if @refusal
        render Components::Kit::Alert.new(tone: :warning) { @refusal }
      elsif @outcome
        outcome
      else
        p(class: "text-sm text-muted", aria: { busy: "true" }) { LOADING }
      end
    end
  end

  private

  def outcome
    p(class: "text-sm text-default", data: { step_outcome_as_of: "" }) { as_of }
    return p(class: "mt-4 text-sm text-muted") { "The plan covers no units." } if @outcome[:units].empty?

    wide
    phone
  end

  def as_of
    stood = "As the organisation stood on #{day(@outcome[:ends_on])}"
    known = @outcome[:known_on] ? "as the Org Graph read it on #{day(@outcome[:known_on])}, when the plan was archived" : "as the Org Graph reads today"
    "#{stood}, #{known}."
  end

  def wide
    div(class: "mt-4 hidden overflow-x-auto md:block") do
      table(class: "w-full text-left text-sm") do
        thead(class: "border-b border-default text-xs text-muted") do
          tr do
            th(scope: "col", class: "py-2 pr-4 font-medium") { "Unit" }
            th(scope: "col", class: "px-4 py-2 text-right font-medium") { "Planned" }
            th(scope: "col", class: "px-4 py-2 text-right font-medium") { "Actual" }
            th(scope: "col", class: "py-2 pl-4 font-medium") { "What differs" }
          end
        end
        tbody do
          @outcome[:units].each do |unit|
            tr(class: "border-b border-subtle align-top", data: { step_outcome_unit: unit[:unit_id] }) do
              th(scope: "row", class: "py-3 pr-4 font-medium text-default break-words") { unit[:name] }
              td(class: "px-4 py-3 text-right tabular-nums text-default") { heads(unit[:planned_heads]) }
              td(class: "px-4 py-3 text-right tabular-nums text-default") { heads(unit[:actual_heads]) }
              td(class: "py-3 pl-4 text-default") { differences(unit) }
            end
          end
        end
      end
    end
  end

  def phone
    ul(class: "mt-4 space-y-3 md:hidden") do
      @outcome[:units].each do |unit|
        li(data: { step_outcome_card: unit[:unit_id] }) do
          render Components::Kit::Card.new(variant: :inset, density: :compact) do |card|
            card.body do
              p(class: "font-medium text-default break-words") { unit[:name] }
              p(class: "text-xs text-muted") { "Planned #{heads(unit[:planned_heads])} · Actual #{heads(unit[:actual_heads])}" }
              div(class: "mt-2") { differences(unit) }
            end
          end
        end
      end
    end
  end

  def differences(unit)
    lines = OUTCOMES.filter_map do |key, label|
      names = unit[:people].select { it[:outcome] == key }.map { it[:name] }
      [ key, label, names ] if names.any?
    end
    seats = unit[:seats]
    return p(class: "text-muted") { "Nobody planned or here" } if lines.empty? && seats.empty?

    dl(class: "space-y-1 text-sm") do
      lines.each do |key, label, names|
        div(class: "flex flex-wrap gap-x-1", data: { step_outcome: key }) do
          dt(class: key == "as_planned" ? "text-muted" : "font-medium text-default") { "#{label}:" }
          dd(class: "break-words text-default") { names.join(", ") }
        end
      end
      seats_line(seats) if seats.any?
    end
  end

  def seats_line(seats)
    filled = seats.filter_map { it[:filled_by_name] }
    open = seats.count { it[:filled_by_id].nil? }
    div(class: "flex flex-wrap gap-x-1", data: { step_outcome: "seats" }) do
      dt(class: "text-muted") { "Seats:" }
      dd(class: "break-words text-default") do
        plain [ ("filled by #{filled.join(', ')}" if filled.any?), ("#{open} not filled" if open.positive?) ].compact.join("; ")
      end
    end
  end

  def heads(value) = value % 1 == 0 ? value.to_i.to_s : value.to_s

  def day(iso) = Views::Plans::ScenarioTable.day(iso)
end
