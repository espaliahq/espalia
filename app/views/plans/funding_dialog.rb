# frozen_string_literal: true

# The Budget tab's "Funding" dialog ([#411](https://github.com/espaliahq/espalia/issues/411)),
# one per tab, for an editor on a scenario. Each position's "Funding…" button
# opens it, and the `funding-form` controller fills in the parts it draws now.
# It lists each line by name and terms, cost centre included, and shows no amount, so the tab
# stays the one place that shows money. It posts to {Plans::FundingsController}.
class Views::Plans::FundingDialog < Views::Base
  include Views::Tenant::BudgetLines::LineText

  ID = "funding-modal"

  # The data a position's "Funding…" button carries: ids and shares only, never an amount.
  #
  # @param url [String] the position's funding path
  # @param name [String] what the tab calls the position
  # @param position [Hash] from `team_planning_funding`
  # @param clearable [Boolean] whether this scenario sets the position's funding itself
  # @return [Hash]
  def self.trigger(url:, name:, position:, clearable:)
    draws = position[:draws].map { "#{it[:budget_line_id]}=#{percent(it[:share]).to_s('F').delete_suffix('.0')}" }
    { action: "click->modal#open", modal_target_id: ID, funding_action: url, funding_name: name,
      funding_draws: draws.join(","), funding_set: clearable.to_s }
  end

  # @param share [String] a draw's share, such as "0.5"
  # @return [BigDecimal] the share as a percentage
  def self.percent(share) = BigDecimal(share.to_s) * 100

  # @param scenario_id [String]
  # @param scenario_name [String]
  # @param lines [Array<Hash>] from `team_planning_budget_lines`
  def initialize(scenario_id:, scenario_name:, lines:)
    @scenario_id = scenario_id
    @scenario_name = scenario_name
    @lines = lines
  end

  def view_template
    render Components::Kit::Modal.new(id: ID, title: "Funding", size: :lg, standalone: false) do |m|
      m.body { funding_forms }
    end
  end

  private

  def funding_forms
    div(class: "space-y-4", data: { controller: "funding-form" }) do
      p(class: "text-sm text-muted") do
        plain "What "
        strong(class: "text-default", data: { funding_form_target: "name" })
        plain " draws on in "
        strong(class: "text-default") { @scenario_name }
        plain ". Give each line its part, out of 100. One line alone takes the whole position."
      end
      set_form
      clear_form
    end
  end

  def set_form
    form(method: "post", class: "space-y-4", data: { funding_form_target: "set", action: "turbo:submit-end->modal#submitted" }) do
      hidden_fields("patch")
      fieldset do
        legend(class: "sr-only") { "Part of the position each line funds" }
        ul(class: "divide-y divide-default rounded-lg border border-default") { @lines.each { line_row(it) } }
      end
      div(class: "flex flex-wrap items-center gap-3") do
        render Components::Kit::Button.new(tone: :brand, type: :submit) { "Save funding" }
        render Components::Kit::Button.new(variant: :outline, data: { action: "click->modal#close" }) { "Cancel" }
      end
    end
  end

  def line_row(line)
    id = "funding-part-#{line[:budget_line_id]}"
    li(class: "flex items-center justify-between gap-3 p-3", data: { funding_line: line[:budget_line_id] }) do
      label(for: id, class: "min-w-0 flex-1 text-sm") do
        span(class: "block font-medium text-default break-words") { line_name(line) }
        span(class: "block text-xs text-muted break-words") { terms_text(line) }
      end
      div(class: "flex w-24 shrink-0 items-center gap-1") do
        input(id:, name: "funding[parts][#{line[:budget_line_id]}]", type: "text", inputmode: "decimal", autocomplete: "off",
              class: "#{Components::Kit::Field::INPUT} text-right", data: { funding_form_target: "part", line_id: line[:budget_line_id] })
        span(class: "text-sm text-muted", aria: { hidden: "true" }) { "%" }
      end
    end
  end

  def clear_form
    form(method: "post", class: "flex flex-wrap items-center justify-between gap-3 border-t border-default pt-4",
         data: { funding_form_target: "clear", action: "turbo:submit-end->modal#submitted" }) do
      hidden_fields("delete")
      p(class: "text-sm text-muted") { "This scenario sets the funding. Clear it to draw on the line the plan finds." }
      render Components::Kit::Button.new(variant: :outline, type: :submit) { "Clear the funding" }
    end
  end

  def hidden_fields(method)
    input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
    input(type: "hidden", name: "_method", value: method)
    input(type: "hidden", name: "scenario_id", value: @scenario_id)
  end
end
