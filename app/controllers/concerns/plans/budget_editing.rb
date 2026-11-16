# frozen_string_literal: true

# Adds, changes and cuts a scenario's budget lines from the Budget tab
# ([#411](https://github.com/espaliahq/espalia/issues/411)), through the same
# Operations as `team_planning_set_budget_line` and `team_planning_cut_budget_line`.
# Editors only, on a scenario: Today holds the organisation's budget as it is.
# A refused form is shown again with what was typed. Amounts appear only in
# the tab and the line's form, never in a flash, so hiding amounts later
# gates those two views alone.
module Plans::BudgetEditing
  extend ActiveSupport::Concern
  include BudgetLineForm

  # GET /planning/:id/budget/lines/new?scenario=:scenario_id
  def new_budget_line
    return unless (plan = budget_editor_plan)
    render budget_line_page(plan, values: {})
  end

  # POST /planning/:id/budget/lines
  def create_budget_line
    return unless (plan = budget_editor_plan)
    Operations::TeamPlanning::SetBudgetLine.call(context: pundit_user, params: { plan_id: plan[:plan_id], scenario_id: line_scenario_id, **operation_params })
    redirect_to budget_plan_path(plan[:plan_id], scenario: line_scenario_id), notice: "Budget line added.", status: :see_other
  rescue Operations::Base::ParameterError => e
    render budget_line_page(plan, values: line_params, error: e.message), status: :unprocessable_content
  end

  # GET /planning/:id/budget/lines/:budget_line_id/edit?scenario=:scenario_id
  def edit_budget_line
    return unless (plan = budget_editor_plan)
    values = held_line
    return redirect_to budget_plan_path(plan[:plan_id], scenario: line_scenario_id), alert: TeamPlanning::LineMoney::REFUSAL, status: :see_other if priced_line_held_back?

    render budget_line_page(plan, values:, budget_line_id: budget_line_id)
  end

  # PATCH /planning/:id/budget/lines/:budget_line_id
  def update_budget_line
    return unless (plan = budget_editor_plan)
    Operations::TeamPlanning::SetBudgetLine.call(context: pundit_user, params: { plan_id: plan[:plan_id], scenario_id: line_scenario_id,
                                                                                  budget_line_id:, **operation_params })
    redirect_to budget_plan_path(plan[:plan_id], scenario: line_scenario_id), notice: "Budget line changed.", status: :see_other
  rescue Operations::Base::ParameterError => e
    render budget_line_page(plan, values: held_line.merge(line_params), budget_line_id:, error: e.message), status: :unprocessable_content
  end

  # DELETE /planning/:id/budget/lines/:budget_line_id
  def cut_budget_line
    return unless (plan = budget_editor_plan)
    Operations::TeamPlanning::CutBudgetLine.call(context: pundit_user, params: { plan_id: plan[:plan_id], scenario_id: line_scenario_id, budget_line_id: })
    redirect_to budget_plan_path(plan[:plan_id], scenario: line_scenario_id), notice: "Budget line cut.", status: :see_other
  rescue Operations::Base::ParameterError => e
    redirect_to budget_plan_path(plan[:plan_id], scenario: line_scenario_id), alert: "Couldn't cut the line: #{e.message}", status: :see_other
  end

  private

  # A viewer is refused as on any plan page. An archived plan and Today land back on the tab, which shows
  # them no form.
  #
  # @return [Hash, nil] the plan, or nil once redirected
  def budget_editor_plan
    plan = read(Operations::TeamPlanning::Plan)
    authorize @plan_record = TeamPlanningPlan.find(plan[:plan_id]), :update?, policy_class: PlanPolicy
    refusal = if @plan_record.archived? then TeamPlanning::PlanAggregate::ARCHIVED
    elsif line_scenario_id == plan[:plan_id] then Operations::TeamPlanning::BudgetLineWrite::BASELINE
    end
    return plan unless refusal

    redirect_to budget_plan_path(plan[:plan_id], scenario: line_scenario_id), alert: refusal, status: :see_other
    nil
  end

  def line_scenario_id = (params[:scenario_id] || params[:scenario]).to_s.downcase

  def budget_line_id = params.expect(:budget_line_id).downcase

  # @raise [ActiveRecord::RecordNotFound] for a line the scenario doesn't hold
  def held_line
    lines = read(Operations::TeamPlanning::BudgetLines, scenario_id: line_scenario_id)[:budget_lines]
    lines.find { it[:budget_line_id] == budget_line_id } || raise(ActiveRecord::RecordNotFound, "No such budget line")
  end

  # A line that carries an amount is read-only without the see-pay right
  # ([#367](https://github.com/espaliahq/espalia/issues/367)), so its form never opens. Only this refusal tells
  # such a member the line has an amount; the tab offers Change on every line alike.
  def priced_line_held_back?
    return false if money_shown?

    plan = TeamPlanning::Repository.new.load_plan(@plan_record.id)
    TeamPlanning::LineMoney.priced?(plan, line_scenario_id, budget_line_id, TeamPlanning::LineMoney::FACET)
  end

  def money_shown? = TeamPlanning::Budget.money_shown?(context: pundit_user, plan: @plan_record)

  def budget_line_page(plan, values:, budget_line_id: nil, error: nil)
    scenarios = read(Operations::TeamPlanning::Scenarios)[:scenarios]
    raise ActiveRecord::RecordNotFound, "No such scenario" if scenarios.none? { it[:scenario_id] == line_scenario_id }

    plan_page(plan, scenarios:, open_tab: :budget,
                    body: Views::Plans::BudgetLineForm.new(plan:, scenarios:, scenario_id: line_scenario_id, values:, budget_line_id:, error:,
                                                           roles: FrameworkState::Role.includes(:levels).order(:name).to_a,
                                                           countries: PayBand.known_countries, money: money_shown?))
  end
end
