# frozen_string_literal: true

# Team Planning's plans index, plan page (#226) and map (#227). Every read goes through
# the Team Planning Operations, as the MCP tools do, so a plan someone isn't
# in is a 404 here and "No such plan" there.
class PlansController < ApplicationController
  include Plans::BudgetEditing

  around_action ->(_, action) { TeamPlanning::Resolution.reusing(&action) }, only: %i[show map timeline_figures budget new_budget_line create_budget_line edit_budget_line update_budget_line cut_budget_line]

  # GET /planning?state=archived
  def index
    authorize TeamPlanningPlan, :index?, policy_class: PlanPolicy
    render index_view
  end

  # POST /planning
  def create
    authorize TeamPlanningPlan, :create?, policy_class: PlanPolicy
    draft = params.expect(plan: [ :name, :base_on, :scope, unit_ids: [] ]).to_h.symbolize_keys
    plan = Operations::TeamPlanning::CreatePlan.call(context: pundit_user, params: { **draft.slice(:name, :base_on), unit_ids: chosen_units(draft) })
    redirect_to plan_path(plan[:plan_id]), notice: "Plan created."
  rescue Operations::Base::ParameterError => e
    render index_view(error: e.message, draft:), status: :unprocessable_content
  end

  # PATCH /planning/:id/scope
  #
  # Widens what the plan covers, or narrows it when nothing planned falls
  # outside ([#338](https://github.com/espaliahq/espalia/issues/338)).
  def scope
    plan = read(Operations::TeamPlanning::Plan)
    authorize TeamPlanningPlan.find(plan[:plan_id]), :update?, policy_class: PlanPolicy
    draft = params.expect(plan: [ :scope, unit_ids: [] ]).to_h.symbolize_keys
    result = Operations::TeamPlanning::SetPlanScope.call(context: pundit_user, params: { plan_id: plan[:plan_id], unit_ids: chosen_units(draft) })
    redirect_to plan_path(plan[:plan_id]), notice: "This plan now covers #{Views::Plans::ScopeDialog.covers(result[:scope])}."
  rescue Operations::Base::ParameterError => e
    redirect_to plan_path(plan[:plan_id]), alert: "Couldn't change what this plan covers: #{e.message}"
  end

  # POST /planning/:id/archive
  def archive
    plan = read(Operations::TeamPlanning::Plan)
    authorize TeamPlanningPlan.find(plan[:plan_id]), :update?, policy_class: PlanPolicy
    Operations::TeamPlanning::ArchivePlan.call(context: pundit_user, params: { plan_id: plan[:plan_id] })
    redirect_to plan_path(plan[:plan_id]), notice: "Plan archived. Restore it whenever you want to work on it again."
  rescue Operations::Base::ParameterError => e
    redirect_to plan_path(plan[:plan_id]), alert: "Couldn't archive this plan: #{e.message}"
  end

  # POST /planning/:id/restore
  def restore
    plan = read(Operations::TeamPlanning::Plan)
    authorize TeamPlanningPlan.find(plan[:plan_id]), :update?, policy_class: PlanPolicy
    Operations::TeamPlanning::RestorePlan.call(context: pundit_user, params: { plan_id: plan[:plan_id] })
    redirect_to plan_path(plan[:plan_id]), notice: "Plan restored. It takes changes again, and its checks cover everything since its base date."
  rescue Operations::Base::ParameterError => e
    redirect_to plan_path(plan[:plan_id]), alert: "Couldn't restore this plan: #{e.message}"
  end

  # DELETE /planning/:id
  #
  # The editor types the plan's name to confirm, so a slip of the mouse can't
  # delete it ([#382](https://github.com/espaliahq/espalia/issues/382)).
  def destroy
    plan = read(Operations::TeamPlanning::Plan)
    authorize TeamPlanningPlan.find(plan[:plan_id]), :destroy?, policy_class: PlanPolicy
    unless params[:confirm_name].to_s.squish == plan[:name]
      return redirect_to(plan_path(plan[:plan_id]), status: :see_other, alert: "The name you typed doesn't match, so the plan is still here.")
    end

    Operations::TeamPlanning::DeletePlan.call(context: pundit_user, params: { plan_id: plan[:plan_id] })
    # The name stays out of the flash, which would carry it in the session cookie after its key is shredded.
    redirect_to plans_path(state: ("archived" if plan[:archived])), status: :see_other, notice: "Plan deleted."
  rescue Operations::Base::ParameterError => e
    redirect_to plan_path(plan[:plan_id]), status: :see_other, alert: "Couldn't delete this plan: #{e.message}"
  end

  # GET /planning/:id?removed_page=:page
  def show
    plan = read(Operations::TeamPlanning::Plan)
    authorize @plan_record = TeamPlanningPlan.find(plan[:plan_id]), :show?, policy_class: PlanPolicy
    scenarios = read(Operations::TeamPlanning::Scenarios)[:scenarios]
    removals = removals(plan, scenarios, scenarios.map { it[:scenario_id] })
    closures = closures(plan, scenarios)
    table = Views::Plans::ScenarioTable.new(plan_id: plan[:plan_id], scenarios:, can_edit: can_edit?, removable: removals.map(&:scenario_id),
                                            closable: closures.to_h { [ it.scenario_id, it.mode ] }, outcomes: true,
                                            extra_columns: cost_columns + capacity_columns(plan, scenarios))
    removed_page = params[:removed_page].to_i.clamp(1..)
    removed = Views::Plans::RemovedScenarios.new(plan_id: plan[:plan_id], open: params.key?(:removed_page),
                                                 read: read(Operations::TeamPlanning::RemovedScenarios, page: removed_page))
    render plan_page(plan, scenarios:, open_tab: :scenarios, body: table, removed:, removals:, closures:, outcomes: outcomes(plan, scenarios))
  end

  # GET /planning/:id/map?scenario=:scenario_id
  #
  # One scenario's organisation, read-only (#227). The baseline, whose id is
  # the plan's, is the default.
  def map
    plan = read(Operations::TeamPlanning::Plan)
    authorize @plan_record = TeamPlanningPlan.find(plan[:plan_id]), :show?, policy_class: PlanPolicy
    scenarios = read(Operations::TeamPlanning::Scenarios)[:scenarios]
    scenario_id = params[:scenario].presence || plan[:plan_id]
    map = read(Operations::TeamPlanning::ScenarioMap, scenario_id:)
    marks = capacity_marks(plan, scenario_id, names: map[:names], live_unit_ids: map[:units].map { it[:id] })
    removals = removals(plan, scenarios, [ scenario_id.downcase ])
    render plan_page(plan, scenarios:, open_tab: :map, undo_in: scenario_id, removals:,
                           body: Views::Plans::ScenarioMap.new(map:, scenarios:, can_edit: can_edit?, removable: removals.map(&:scenario_id),
                                                               roles: (map_roles if can_edit? && scenario_id != plan[:plan_id]) || [],
                                                               can_upload_pay: policy_for(@plan_record).upload_pay? && !@plan_record.archived?,
                                                               **map_hooks(cost_hooks(map), capacity_hooks(marks))))
  end

  # GET /planning/:id/timeline?scenario=:scenario_id&step=:index
  #
  # One path from the baseline to `scenario` along the calendar ([#298](https://github.com/espaliahq/espalia/issues/298)).
  # With no scenario it follows the first "then" at each step to a leaf. A
  # phone shows one step at a time, `step` from the left.
  def timeline
    plan = read(Operations::TeamPlanning::Plan)
    authorize @plan_record = TeamPlanningPlan.find(plan[:plan_id]), :show?, policy_class: PlanPolicy
    scenarios = read(Operations::TeamPlanning::Scenarios)[:scenarios]
    scenario_id = params[:scenario].presence || Views::Plans::Timeline.first_leaf(scenarios, plan[:plan_id])
    timeline = read(Operations::TeamPlanning::Timeline, scenario_id:)
    closures = closures(plan, scenarios, return_to: timeline_plan_path(plan[:plan_id], scenario: params[:scenario].presence, step: params[:step].presence))
    render plan_page(plan, scenarios:, open_tab: :timeline, closures:, outcomes: outcomes(plan, scenarios),
                           body: Views::Plans::Timeline.new(timeline:, scenarios:, step: params[:step].to_i, can_edit: can_edit?,
                                                            closable: closures.to_h { [ it.scenario_id, it.mode ] }, outcomes: true))
  end

  # GET /planning/:id/timeline/figures?scenario=:scenario_id&layout=phone&step=:index
  #
  # What each step on that path costs, leaves unfunded and can deliver
  # ([#452](https://github.com/espaliahq/espalia/issues/452)), as a lazy frame
  # the timeline loads after it is drawn. A phone's frame shows `step` alone.
  def timeline_figures
    plan = read(Operations::TeamPlanning::Plan)
    authorize @plan_record = TeamPlanningPlan.find(plan[:plan_id]), :show?, policy_class: PlanPolicy
    scenarios = read(Operations::TeamPlanning::Scenarios)[:scenarios]
    scenario_id = params[:scenario].presence || Views::Plans::Timeline.first_leaf(scenarios, plan[:plan_id])
    return redirect_to timeline_plan_path(plan[:plan_id], scenario: scenario_id, step: params[:step].presence) unless turbo_frame_request?

    render Views::Plans::TimelineFigures.new(figures: read(Operations::TeamPlanning::TimelineFigures, scenario_id:), scenarios:,
                                             phone: params[:layout] == "phone", step: params[:step].to_i)
  end

  # GET /planning/:id/changes?scenario=:scenario_id
  #
  # What the Org Graph has learned since the base, and where one scenario's
  # planned changes stand against it ([#287](https://github.com/espaliahq/espalia/issues/287)).
  # The baseline is the default.
  def changes
    plan = read(Operations::TeamPlanning::Plan)
    authorize @plan_record = TeamPlanningPlan.find(plan[:plan_id]), :show?, policy_class: PlanPolicy
    scenarios = read(Operations::TeamPlanning::Scenarios)[:scenarios]
    scenario_id = params[:scenario].presence || plan[:plan_id]
    tab = Views::Plans::ChangesTab.new(plan:, scenarios:, drift: read(Operations::TeamPlanning::Drift),
                                       status: read(Operations::TeamPlanning::Status, scenario_id:),
                                       attention: read(Operations::TeamPlanning::Attention, scenario_id:), can_edit: can_edit?,
                                       see_pay: policy_for(@plan_record).see_pay?)
    render plan_page(plan, scenarios:, open_tab: :changes, body: tab, undo_in: scenario_id)
  end

  # GET /planning/:id/checks?scenario=:scenario_id
  #
  # What no longer fits in one scenario, grouped by the check that found it
  # ([#350](https://github.com/espaliahq/espalia/issues/350)). The baseline is the default.
  def checks
    plan = read(Operations::TeamPlanning::Plan)
    authorize @plan_record = TeamPlanningPlan.find(plan[:plan_id]), :show?, policy_class: PlanPolicy
    scenarios = read(Operations::TeamPlanning::Scenarios)[:scenarios]
    scenario_id = params[:scenario].presence || plan[:plan_id]
    linked_ids = read(Operations::TeamPlanning::Status, scenario_id:)[:statuses].to_set { it[:change_id] }
    tab = Views::Plans::ChecksTab.new(plan:, scenarios:, attention: read(Operations::TeamPlanning::Attention, scenario_id:), linked_ids:)
    render plan_page(plan, scenarios:, open_tab: :checks, body: tab, undo_in: scenario_id)
  end

  # GET /planning/:id/budget?scenario=:scenario_id
  #
  # A scenario's budget lines and what draws on them
  # ([#395](https://github.com/espaliahq/espalia/issues/395)). Today, the
  # default, has no period, so it shows the lines as approved.
  def budget
    plan = read(Operations::TeamPlanning::Plan)
    authorize @plan_record = TeamPlanningPlan.find(plan[:plan_id]), :show?, policy_class: PlanPolicy
    scenarios = read(Operations::TeamPlanning::Scenarios)[:scenarios]
    scenario_id = (params[:scenario].presence || plan[:plan_id]).downcase
    lines = read(Operations::TeamPlanning::BudgetLines, scenario_id:)
    tab = if scenario_id == plan[:plan_id]
            Views::Plans::BudgetTab.new(plan:, scenarios:, lines:)
    else
            Views::Plans::BudgetTab.new(plan:, scenarios:, lines:, can_edit: can_edit?, budget: read(Operations::TeamPlanning::Budget, scenario_id:),
                                        funding: read(Operations::TeamPlanning::Funding, scenario_id:),
                                        map: read(Operations::TeamPlanning::ScenarioMap, scenario_id:), funded_here: funded_here(scenario_id))
    end
    render plan_page(plan, scenarios:, open_tab: :budget, body: tab, undo_in: scenario_id)
  end

  # The positions whose funding this scenario sets itself, which are the only
  # ones `team_planning_clear_change` will hand back.
  #
  # @return [Set<String>]
  def funded_here(scenario_id)
    return Set.new unless can_edit?

    read(Operations::TeamPlanning::Overrides, scenario_id:)[:overrides].filter_map { it[:subject_id] if it[:facet] == "funding" }.to_set
  end

  # GET /planning/:id/update-to-today
  #
  # What updating the plan to today would take in, for an editor to confirm
  # ([#337](https://github.com/espaliahq/espalia/issues/337)).
  def rebase
    plan = read(Operations::TeamPlanning::Plan)
    authorize @plan_record = TeamPlanningPlan.find(plan[:plan_id]), :update?, policy_class: PlanPolicy
    preview = Operations::TeamPlanning::RebasePreview.call(context: pundit_user, params: { plan_id: plan[:plan_id] })
    scenarios = read(Operations::TeamPlanning::Scenarios)[:scenarios]
    render plan_page(plan, scenarios:, open_tab: :changes, body: Views::Plans::UpdateToToday.new(plan:, scenarios:, preview:))
  rescue Operations::Base::ParameterError => e
    redirect_to changes_plan_path(plan[:plan_id]), alert: "Can't update to today: #{e.message}"
  end

  # POST /planning/:id/update-to-today
  #
  # Takes the base the preview read, so an update made since is refused
  # rather than taken in unseen.
  def rebase_plan
    plan = read(Operations::TeamPlanning::Plan)
    authorize TeamPlanningPlan.find(plan[:plan_id]), :update?, policy_class: PlanPolicy
    today = Tenant.today.iso8601
    # A second click lands after the first has moved the base to the day it confirmed.
    return redirect_to(changes_plan_path(plan[:plan_id]), notice: "Updated to today, #{day(today)}.") if plan[:base_on] == today && params[:to] == today
    return redirect_to(rebase_plan_path(plan[:plan_id]), alert: "The day has turned since you looked, so check the update again.") if params[:to] != today

    result = Operations::TeamPlanning::RebasePlan.call(context: pundit_user, params: { plan_id: plan[:plan_id], base_on: params[:base_on] })
    redirect_to changes_plan_path(plan[:plan_id]), notice: rebased(result)
  rescue Operations::Base::ParameterError => e
    redirect_to changes_plan_path(plan[:plan_id]), alert: "Couldn't update to today: #{e.message}"
  end

  # GET /planning/:id/scenarios/:scenario_id/split
  #
  # The changes a scenario makes, to choose the agreed part from, with what
  # each can't go across without ([#360](https://github.com/espaliahq/espalia/issues/360)).
  def split
    plan = read(Operations::TeamPlanning::Plan)
    authorize @plan_record = TeamPlanningPlan.find(plan[:plan_id]), :update?, policy_class: PlanPolicy
    render split_page(plan)
  rescue Operations::Base::ParameterError => e
    redirect_to plan_path(plan[:plan_id]), alert: "Can't split this scenario: #{e.message}"
  end

  # POST /planning/:id/scenarios/:scenario_id/split
  #
  # A refusal shows the page again with the choice kept and the operation's
  # reason, so the editor can add what a change needs.
  def split_scenario
    plan = read(Operations::TeamPlanning::Plan)
    authorize @plan_record = TeamPlanningPlan.find(plan[:plan_id]), :show?, policy_class: PlanPolicy
    draft = { event_ids: Array(params[:event_ids]).compact_blank, name: params[:name].to_s }
    result = Operations::TeamPlanning::SplitScenario.call(context: pundit_user,
                                                          params: { plan_id: plan[:plan_id], scenario_id: params.expect(:scenario_id), **draft })
    count = (draft[:event_ids] & result[:moved_event_ids]).size
    redirect_to timeline_plan_path(plan[:plan_id], scenario: result[:agreed_id], step: split_step(result)),
                notice: "Split #{count} #{'change'.pluralize(count)} off into #{result[:name]}."
  rescue Operations::Base::ParameterError => e
    refused = -> { redirect_to plan_path(plan[:plan_id]), alert: "Couldn't split the scenario: #{e.message}" }
    return refused.call unless can_edit?

    begin
      render split_page(plan, draft:, error: e.message), status: :unprocessable_content
    rescue Operations::Base::ParameterError
      refused.call
    end
  end

  # GET /planning/:id/scenarios/:scenario_id/dates
  #
  # A step's dates, and what moving them would move once the editor previews
  # new ones ([#404](https://github.com/espaliahq/espalia/issues/404)).
  def dates
    plan = read(Operations::TeamPlanning::Plan)
    authorize @plan_record = TeamPlanningPlan.find(plan[:plan_id]), :update?, policy_class: PlanPolicy
    render dates_page(plan, draft: period_draft)
  end

  # POST /planning/:id/scenarios/:scenario_id/dates
  #
  # Saves the dates the preview showed. A refusal shows the page again with
  # those dates and the reason.
  def set_dates
    plan = read(Operations::TeamPlanning::Plan)
    authorize @plan_record = TeamPlanningPlan.find(plan[:plan_id]), :update?, policy_class: PlanPolicy
    draft = period_draft
    Operations::TeamPlanning::SetScenarioPeriod.call(context: pundit_user,
                                                     params: { plan_id: plan[:plan_id], scenario_id: params.expect(:scenario_id), **draft })
    redirect_to dates_back(plan[:plan_id]), notice: "Saved the dates of #{dates_scenario_name}."
  rescue Operations::Base::ParameterError => e
    render dates_page(plan, draft:, error: e.message, preview: false), status: :unprocessable_content
  end

  # GET /planning/:id/pay-upload?scenario=:scenario_id
  #
  # A file of actual pay to preview, then hold ([#323](https://github.com/espaliahq/espalia/issues/323)).
  # Anyone but an editor with the see-pay right gets the same 404 as someone outside the plan.
  def pay_upload
    plan = pay_uploader_plan
    return redirect_to(plan_path(plan[:plan_id]), alert: TeamPlanning::PlanAggregate::ARCHIVED) if @plan_record.archived?

    render pay_upload_page(plan, scenario_id: params[:scenario].presence || plan[:plan_id])
  end

  # POST /planning/:id/pay-upload
  #
  # Previews into the page's frame, or, with the preview's signature and the
  # same file, holds the pay and returns to the map. The file is read here
  # and never kept: its tempfile goes at the end of the request.
  def upload_pay
    plan = pay_uploader_plan
    if @plan_record.archived?
      return render_turbo_frame_recovery(TeamPlanning::PlanAggregate::ARCHIVED) if turbo_frame_request?

      return redirect_to(plan_path(plan[:plan_id]), alert: TeamPlanning::PlanAggregate::ARCHIVED)
    end

    upload = params.permit(:scenario_id, :basis, :signature, :intent)
    scenario_id = upload[:scenario_id].presence || plan[:plan_id]
    return render(pay_upload_page(plan, scenario_id:, basis: upload[:basis], error: "Choose a file to upload."), status: :unprocessable_content) unless params[:file].respond_to?(:read)
    return render(pay_upload_page(plan, scenario_id:, error: "Say what the amounts are, actual or full-time pay."), status: :unprocessable_content) if upload[:basis].blank?

    csv = params[:file].read(TeamPlanning::PayUpload::MAX_BYTES + 1).to_s
    signature = upload[:signature].presence if upload[:intent] == "confirm"
    result = Operations::TeamPlanning::UploadActualPay.call(context: pundit_user, params: { plan_id: plan[:plan_id], scenario_id:, basis: upload[:basis], csv:, signature: }.compact)
    return render(pay_upload_page(plan, scenario_id:, basis: upload[:basis], preview: result)) unless signature

    redirect_to map_plan_path(plan[:plan_id], scenario: (scenario_id unless scenario_id == plan[:plan_id])), notice: pay_held(result)
  rescue Operations::Base::ParameterError => e
    render pay_upload_page(plan, scenario_id:, basis: upload[:basis], error: "Couldn't hold the pay: #{e.message}."), status: :unprocessable_content
  end

  private

  # The column a phone opens on: the agreed part shares one with the rest.
  # The split has already happened, so a failed read lands on the timeline's first column rather than a 404.
  def split_step(result)
    halves = result.values_at(:agreed_id, :scenario_id)
    read(Operations::TeamPlanning::Timeline, scenario_id: result[:agreed_id])[:columns]
      .index { ([ it[:scenario_id] ] + it[:alternative_ids]).intersect?(halves) }
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def split_page(plan, draft: {}, error: nil)
    scenario_id = params.expect(:scenario_id).downcase
    needs = Operations::TeamPlanning::SplitNeeds.call(context: pundit_user, params: { plan_id: plan[:plan_id], scenario_id: })
    scenarios = read(Operations::TeamPlanning::Scenarios)[:scenarios]
    scenario = scenarios.find { it[:scenario_id] == scenario_id }
    plan_page(plan, scenarios:, open_tab: :scenarios,
                    body: Views::Plans::SplitScenario.new(plan:, scenario:, needs:, draft:, error:))
  end

  # A ticked "No end date" sends an empty end, which takes the end away.
  def period_draft
    draft = params.permit(:starts_on, :ends_on).to_h.symbolize_keys.compact_blank
    params[:no_end] == "1" ? draft.merge(ends_on: "") : draft
  end

  def dates_page(plan, draft:, error: nil, preview: true)
    scenario_id = params.expect(:scenario_id).downcase
    scenarios = read(Operations::TeamPlanning::Scenarios)[:scenarios]
    scenario = scenarios.find { it[:scenario_id] == scenario_id && Views::Plans::ScenarioTable.dated?(it) }
    raise ActiveRecord::RecordNotFound, "No such step" unless scenario

    if preview && draft.key?(:ends_on)
      begin
        previewed = Operations::TeamPlanning::PeriodPreview.call(context: pundit_user, params: { plan_id: plan[:plan_id], scenario_id:, **draft })
      rescue Operations::Base::ParameterError => e
        error = e.message
      end
    end
    plan_page(plan, scenarios:, open_tab: params[:from] == "map" ? :map : :scenarios,
                    body: Views::Plans::ScenarioDates.new(plan:, scenarios:, scenario:, draft:, preview: previewed, error:, from: params[:from],
                                                                map_scenario: params[:map_scenario].presence))
  end

  def dates_scenario_name
    id = params.expect(:scenario_id).downcase
    read(Operations::TeamPlanning::Scenarios)[:scenarios].find { it[:scenario_id] == id }&.dig(:name)
  end

  def dates_back(plan_id) = params[:from] == "map" ? map_plan_path(plan_id, scenario: params[:map_scenario].presence || params[:scenario_id]) : plan_path(plan_id)

  def pay_uploader_plan
    plan = read(Operations::TeamPlanning::Plan)
    @plan_record = TeamPlanningPlan.find(plan[:plan_id])
    raise ActiveRecord::RecordNotFound, "No such plan" unless policy_for(@plan_record).upload_pay?

    authorize @plan_record, :upload_pay?, policy_class: PlanPolicy
    plan
  end

  def pay_upload_page(plan, scenario_id:, basis: nil, preview: nil, error: nil)
    scenarios = read(Operations::TeamPlanning::Scenarios)[:scenarios]
    plan_page(plan, scenarios:, open_tab: :map,
                    body: Views::Plans::PayUpload.new(plan:, scenarios:, scenario_id:, basis:, preview:, error:))
  end

  def pay_held(result)
    written = result[:written]
    return "Nothing to change: the plan already holds this pay." if written.zero?

    "Held actual pay for #{written} #{written == 1 ? 'person' : 'people'}."
  end

  # "Chosen units" with none ticked is a slip, not the whole organisation.
  def chosen_units(draft)
    return [] unless draft[:scope] == "chosen"
    raise Operations::Base::ParameterError, "Choose at least one unit, or cover the whole organisation" if Array(draft[:unit_ids]).compact_blank.empty?

    Array(draft[:unit_ids]).compact_blank
  end

  def rebased(result)
    count = result[:conflicts].size
    carried = count.zero? ? "" : " #{count} planned #{count == 1 ? 'change stays' : 'changes stay'} conflicting."
    "Updated to today, #{day(result[:base_on])}.#{carried}"
  end

  def day(iso) = I18n.l(Date.iso8601(iso), format: "%-d %b %Y")

  # Cost comes before capacity, in the strips above the map and beside each
  # unit's name.
  def map_hooks(*hooks)
    summaries = hooks.filter_map { it[:summary] }
    marks = %i[unit_marks person_marks position_marks].to_h do |key|
      calls = hooks.filter_map { it[key] }
      [ key, ->(*args) { calls.flat_map { it.call(*args) } } ]
    end
    { **marks, summary: summaries.any? ? Views::Plans::MapSummaries.new(summaries) : nil }
  end

  # Cost shows once a pay band prices something; a scenario that can't be
  # priced keeps its map.
  def cost_hooks(map)
    marks = Views::Plans::CostMarks.new(cost: read(Operations::TeamPlanning::Cost, scenario_id: map[:scenario_id]), map:)
    marks.priced? ? { unit_marks: marks.unit_marks, summary: Views::Plans::CostStrip.new(marks:) } : {}
  rescue ActiveRecord::RecordNotFound
    {}
  end

  def cost_columns
    return [] unless TeamPlanning::PricingInputs.for(@plan_record).bands.any?

    costs = read(Operations::TeamPlanning::ScenarioCosts)
    rows = costs[:scenarios].index_by { it[:scenario_id] }
    priced = rows.values.any? { |row| row[:total]&.values_at(:scenario, :baseline)&.compact&.any? { it[:native].any? } }
    return [] unless priced

    [ Views::Plans::ScenarioTable::Column.new(heading: "Cost", cell: ->(scenario) {
      Views::Plans::CostCell.new(row: rows[scenario[:scenario_id]], reference: costs[:reference_currency])
    }) ]
  end

  # Every scenario is measured against the baseline, as cost is, so its
  # capacity and Today's are read side by side.
  def capacity_marks(plan, scenario_id, names: {}, live_unit_ids: nil)
    @capacity ||= {}
    scenario, baseline = [ scenario_id, plan[:plan_id] ].map { @capacity[it] ||= read(Operations::TeamPlanning::Capacity, scenario_id: it) }
    Views::Plans::CapacityMarks.new(scenario:, baseline:, names: scenario[:names].merge(names), live_unit_ids:)
  end

  def capacity_hooks(marks)
    return {} unless marks.measured?

    { unit_marks: marks.unit_marks, person_marks: marks.person_marks, position_marks: marks.position_marks,
      summary: Views::Plans::CapacityStrip.new(marks:) }
  end

  # A scenario that no longer resolves says so in its cell rather than
  # taking the whole table with it.
  def capacity_columns(plan, scenarios)
    marks = scenarios.to_h { [ it[:scenario_id], capacity_marks_or_nil(plan, it[:scenario_id]) ] }
    return [] if marks.values.all? { it && !it.measured? }

    [ Views::Plans::ScenarioTable::Column.new(heading: "Capacity", cell: ->(scenario) { capacity_cell(marks[scenario[:scenario_id]]) }) ]
  end

  def capacity_marks_or_nil(plan, scenario_id)
    capacity_marks(plan, scenario_id)
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def capacity_cell(marks)
    return Views::Plans::CapacityUnitTotal.new(totals: [], baseline: false, empty: "Can't be counted") unless marks

    Views::Plans::CapacityUnitTotal.new(totals: marks.totals, baseline: marks.baseline?, empty: "None counted")
  end

  # @param undo_in [String, nil] the scenario the open tab shows, whose Undo and Redo the tab strip offers
  # @param removals [Array<Views::Plans::RemoveScenarioDialog>] the Remove dialogs the open tab's triggers open
  # @param closures [Array<Views::Plans::StepClosureDialog>] the Close and Reopen dialogs the open tab's triggers open
  # @param outcomes [Array<Views::Plans::StepOutcomeDialog>] the closed steps' outcome dialogs the open tab's triggers open
  def plan_page(plan, open_tab:, scenarios: read(Operations::TeamPlanning::Scenarios)[:scenarios], body: nil, undo_in: nil, removed: nil,
                removals: [], closures: [], outcomes: [])
    members = read(Operations::TeamPlanning::PlanMembers)[:members]
    Views::Plans::ShowView.new(
      plan:,
      scenarios:,
      members:,
      see_pay: see_pay(members),
      tabs: [ Views::Plans::ShowView::Tab.new(key: :scenarios, label: "Scenarios", href: plan_path(plan[:plan_id])),
              Views::Plans::ShowView::Tab.new(key: :map, label: "Map", href: map_plan_path(plan[:plan_id])),
              Views::Plans::ShowView::Tab.new(key: :timeline, label: "Timeline", href: timeline_plan_path(plan[:plan_id])),
              Views::Plans::ShowView::Tab.new(key: :changes, label: "Changes", href: changes_plan_path(plan[:plan_id])),
              Views::Plans::ShowView::Tab.new(key: :checks, label: "Checks", href: checks_plan_path(plan[:plan_id])),
              Views::Plans::ShowView::Tab.new(key: :budget, label: "Budget", href: budget_plan_path(plan[:plan_id])) ],
      open_tab:,
      body:,
      can_edit: can_edit?,
      can_archive: editor? && !plan[:archived],
      can_restore: editor? && plan[:archived].present?,
      can_delete: policy_for(@plan_record).destroy?,
      coverable_units: (read(Operations::TeamPlanning::CoverableUnits)[:units] if can_edit?),
      removed:,
      removals:,
      closures:,
      outcomes:,
      undo_step: (read(Operations::TeamPlanning::UndoStep, scenario_id: undo_in.downcase) if can_edit? && undo_in),
      panel_open: Views::Plans::ShowView.panel_open?(
        url: params[Views::Plans::ShowView::PANEL_URL_KEY], cookie: cookies[Views::Plans::ShowView.panel_cookie(current_user)],
        open_tab:, scenarios:
      ),
      **layout
    )
  end

  def index_view(error: nil, draft: {})
    can_create = policy_for(TeamPlanningPlan).create?
    archived = params[:state] == "archived"
    Views::Plans::IndexView.new(
      plans: Operations::TeamPlanning::Plans.call(context: pundit_user, params: { state: archived ? "archived" : "live" })[:plans],
      archived:,
      can_create:,
      units: can_create ? Operations::TeamPlanning::CoverableUnits.call(context: pundit_user)[:units] : [],
      error:,
      draft:,
      **layout
    )
  end

  # The Operations decide who may open a plan, so their "No such plan" is
  # this page's 404, as it is the MCP tools' refusal.
  def read(operation, **extra)
    operation.call(context: pundit_user, params: { plan_id: params.expect(:id), **extra })
  rescue Operations::Base::ParameterError => e
    raise ActiveRecord::RecordNotFound, e.message
  end

  def policy_for(record) = PlanPolicy.new(pundit_user, record)

  def see_pay(members)
    { can_manage_see_pay: policy_for(@plan_record).manage_see_pay? && !@plan_record.archived?,
      reachable_ids: PlanPolicy.reachable_ids(members.pluck(:person_id)),
      locked_out: PlanPolicy.locked_out?(@plan_record) && !PlanPolicy.frozen?(@plan_record) }
  end

  # A Close dialog for each step ready to close, and a Reopen one for the last
  # closed, while an editor can change the plan.
  def closures(plan, scenarios, return_to: nil)
    return [] if !can_edit? || PlanPolicy.frozen?(@plan_record)

    Views::Plans::StepClosureDialog.offered(scenarios).map do |scenario, mode|
      Views::Plans::StepClosureDialog.new(plan_id: plan[:plan_id], scenario:, mode:, scenarios:, return_to:)
    end
  end

  # An outcome dialog for each closed step, for any member.
  def outcomes(plan, scenarios)
    scenarios.select { Views::Plans::StepOutcomeDialog.offered?(it) }.map { Views::Plans::StepOutcomeDialog.new(plan_id: plan[:plan_id], scenario: it) }
  end

  # A Remove dialog for each of `ids` an editor may remove: never the baseline,
  # a closed step or one not taken, nor anything on an archived or frozen plan. Only a dialog that offers
  # Remove asks the operation how much hidden pay goes with it, all in one load of the plan.
  def removals(plan, scenarios, ids)
    return [] if !can_edit? || PlanPolicy.frozen?(@plan_record)

    offered = scenarios.select { ids.include?(it[:scenario_id]) && it[:scenario_id] != plan[:plan_id] && !Views::Plans::StepClosureDialog.settled?(it) }
                       .map { [ it, Views::Plans::RemoveScenarioDialog.forks(it, scenarios) ] }
    notices = Operations::TeamPlanning::RemoveScenario.approval_notices(
      context: pundit_user, plan_id: plan[:plan_id], scenario_ids: offered.filter_map { |scenario, forks| scenario[:scenario_id] if forks.empty? }
    )
    offered.map do |scenario, forks|
      Views::Plans::RemoveScenarioDialog.new(plan_id: plan[:plan_id], scenario:, forks:, hidden_pay: notices[scenario[:scenario_id]])
    end
  end

  # The roles a position can be, for the map's open and edit dialogs.
  def map_roles = FrameworkState::Role.includes(:levels).order(:name).to_a

  # An archived plan takes no changes, so its editors see it as its viewers do.
  def can_edit?
    return @can_edit if defined?(@can_edit)

    @can_edit = editor? && !@plan_record.archived?
  end

  def editor?
    return @editor if defined?(@editor)

    @editor = policy_for(@plan_record).update?
  end

  def layout
    { user: current_user, current_tenant: ActsAsTenant.current_tenant,
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a } }
  end
end
