# frozen_string_literal: true

# Reads the budget line form ({Views::Tenant::BudgetLines::LineFields}) into an
# operation's parameters, for the tenant's budget page and a plan's Budget tab.
module BudgetLineForm
  extend ActiveSupport::Concern

  FIELDS = %i[starts_on ends_on origin approved_on amount currency period head_count position location cost_centre].freeze
  # Commas only in thousands groups, so a decimal comma such as 52,50 is refused rather than read as 5250.
  GROUPED = /\A\d{1,3}(,\d{3})+(\.\d+)?\z/

  private

  # The form's one position picker names a role or a level, "role:<id>" or "level:<id>".
  # Approved on stays on screen whatever the origin, and its hint says it counts for a new position only.
  def operation_params
    values = line_params
    values.delete(:approved_on) unless values[:origin] == "new"
    kind, id = values.delete(:position).to_s.split(":", 2)
    values.merge(role_id: (id if kind == "role"), level_id: (id if kind == "level")).compact_blank
  end

  # Figures arrive as typed, so the spaces and thousands separators a person types are dropped here.
  def line_params
    values = params.expect(budget_line: FIELDS).to_h.symbolize_keys
    %i[amount head_count].each { |name| values[name] = ungrouped(values[name]) if values.key?(name) }
    values
  end

  def ungrouped(figure)
    figure = figure.to_s.delete(" ")
    figure.match?(GROUPED) ? figure.delete(",") : figure
  end
end
