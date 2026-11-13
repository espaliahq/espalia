# frozen_string_literal: true

# Compare with a date (#139), under the Units view's heading: a form for the
# window, then what changed in it. The window lives in the URL, so a
# comparison can be shared.
class Views::Tenant::OrgGraph::ComparisonBar < Views::Base
  include Phlex::Rails::Helpers::Routes

  # @param comparison [OrgGraph::DateComparison, nil] nil when no date is picked
  # @param error [String, nil] why the dates asked for made no window
  # @param values [Hash] the form's values as asked: "from", "to" and "by"
  # @param unit_id [String, nil] the unit open, kept when the window changes
  # @param today [Date]
  def initialize(comparison:, error:, values:, unit_id:, today: Date.current)
    @comparison = comparison
    @error = error
    @values = values
    @unit_id = unit_id
    @today = today
  end

  def view_template
    section(id: "org-graph-comparison", class: "mt-4 space-y-3", aria: { label: "Compare with a date" }) do
      date_form
      if @error
        render Components::Kit::Alert.new(tone: :danger, size: :sm) { @error }
      elsif @comparison
        changes_summary
      end
    end
  end

  private

  def date_form
    details(open: @comparison || @error ? true : nil, class: "group") do
      summary(class: "inline-flex items-center gap-1 text-sm font-medium text-link hover:text-link-hover underline") do
        plain(@comparison ? "Change the dates" : "Compare with a date")
      end
      form(action: tenant_org_graph_path, method: "get", class: "mt-3 flex flex-wrap items-end gap-4") do
        input(type: "hidden", name: "unit", value: @unit_id) if @unit_id
        date_field("comparison-from", "from", "Compare with", @values["from"])
        date_field("comparison-to", "to", "Up to", @values["to"].presence || @today.iso8601)
        mode_choice
        div(class: "flex items-center gap-3") do
          render Components::Kit::Button.new(type: "submit", variant: :solid, tone: :brand, size: :sm) { "Compare" }
          if @comparison || @error
            render Components::Kit::Button.new(variant: :link, tone: :brand, size: :sm, href: tenant_org_graph_path(unit: @unit_id)) do
              "Clear"
            end
          end
        end
      end
    end
  end

  def date_field(id, name, label_text, value)
    div do
      label(for: id, class: "block text-xs font-medium text-muted") { label_text }
      latest = name == "from" ? @today - 1 : @today
      input(type: "date", id:, name:, value:, max: latest.iso8601, required: name == "from",
            class: [ Components::Kit::Field::INPUT, "mt-1" ])
    end
  end

  def mode_choice
    fieldset do
      legend(class: "block text-xs font-medium text-muted") { "Show what" }
      div(class: "mt-1 flex flex-wrap gap-x-4 gap-y-1") do
        { "effective" => "Took effect in the window", "learned" => "We learned in the window" }.each do |value, text|
          label(class: "inline-flex items-center gap-2 text-sm text-default") do
            input(type: "radio", name: "by", value:, checked: mode == value, class: Components::Kit::Field::RADIO)
            plain text
          end
        end
      end
    end
  end

  def mode = @values["by"] == "learned" ? "learned" : "effective"

  def changes_summary
    render Components::Kit::Card.new(density: :compact) do |card|
      card.body do
        div(class: "pt-3") do
          h3(class: "font-semibold text-default") { "What changed: #{@comparison.window_label.downcase_first}" }
          p(class: "mt-1 text-sm text-muted") { window_sentence }
          counts
          retirements
        end
      end
    end
  end

  def window_sentence
    from, to = [ @comparison.window.from, @comparison.window.to ].map { day(it) }
    if @comparison.learned?
      "What the Org Graph learned from the end of #{from} to the end of #{to}, in UTC, " \
        "whatever day each change took effect. Units and cards are marked below."
    else
      "Changes that took effect after #{from}, up to and including #{to}. Units and cards are marked below."
    end
  end

  def counts
    dl(class: "mt-3 grid grid-cols-2 gap-x-4 gap-y-2 sm:grid-cols-4 xl:grid-cols-8") do
      @comparison.counts.each do |label, count|
        div do
          dt(class: "text-xs text-muted") { label }
          dd(class: "text-lg font-semibold tabular-nums text-default") { count.to_s }
        end
      end
    end
  end

  def retirements
    list = @comparison.retirements
    return if list.empty?

    div(class: "mt-3 border-t border-subtle pt-2") do
      p(class: "text-xs font-semibold text-muted") { "Retired in the window" }
      ul(class: "mt-1 space-y-1 text-sm text-default") do
        list.each do |retirement|
          li do
            span(class: "font-medium") { retirement.name }
            plain " #{retirement_text(retirement)}"
          end
        end
      end
    end
  end

  def retirement_text(retirement)
    text = "retired #{day(retirement.last_day)}"
    text += ", succeeded by #{retirement.successors.to_sentence}" if retirement.successors.any?
    retirement.withdrawn ? "#{text} (withdrawn)" : text
  end

  def day(date) = @comparison.day(date)
end
