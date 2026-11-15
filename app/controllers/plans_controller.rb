# frozen_string_literal: true

# Team Planning's plans index, plan page (#226) and map (#227). Every read goes through
# the Team Planning Operations, as the MCP tools do, so a plan someone isn't
# in is a 404 here and "No such plan" there.
class PlansController < ApplicationController
  # GET /planning
  def index
    authorize TeamPlanningPlan, :index?, policy_class: PlanPolicy
    render index_view
  end

  # POST /planning
  def create
    authorize TeamPlanningPlan, :create?, policy_class: PlanPolicy
    draft = params.expect(plan: [ :name, :base_on ]).to_h.symbolize_keys
    plan = Operations::TeamPlanning::CreatePlan.call(context: pundit_user, params: draft)
    redirect_to plan_path(plan[:plan_id]), notice: "Plan created."
  rescue Operations::Base::ParameterError => e
    render index_view(error: e.message, draft:), status: :unprocessable_content
  end

  # GET /planning/:id
  def show
    plan = read(Operations::TeamPlanning::Plan)
    authorize @plan_record = TeamPlanningPlan.find(plan[:plan_id]), :show?, policy_class: PlanPolicy
    scenarios = read(Operations::TeamPlanning::Scenarios)[:scenarios]
    table = Views::Plans::ScenarioTable.new(plan_id: plan[:plan_id], scenarios:, can_edit: can_edit?,
                                            extra_columns: cost_columns + capacity_columns(plan, scenarios))
    render plan_page(plan, scenarios:, open_tab: :scenarios, body: table)
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
    render plan_page(plan, scenarios:, open_tab: :map,
                           body: Views::Plans::ScenarioMap.new(map:, scenarios:, can_edit: can_edit?,
                                                               **map_hooks(cost_hooks(plan, map), capacity_hooks(marks))))
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
    render plan_page(plan, scenarios:, open_tab: :timeline,
                           body: Views::Plans::Timeline.new(timeline:, scenarios:, step: params[:step].to_i))
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
                                       attention: read(Operations::TeamPlanning::Attention, scenario_id:), can_edit: can_edit?)
    render plan_page(plan, scenarios:, open_tab: :changes, body: tab)
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
    today = Time.now.utc.to_date.iso8601
    # A second click lands after the first has moved the base to the day it confirmed.
    return redirect_to(changes_plan_path(plan[:plan_id]), notice: "Updated to today, #{day(today)}.") if plan[:base_on] == today && params[:to] == today
    return redirect_to(rebase_plan_path(plan[:plan_id]), alert: "The day has turned since you looked, so check the update again.") if params[:to] != today

    result = Operations::TeamPlanning::RebasePlan.call(context: pundit_user, params: { plan_id: plan[:plan_id], base_on: params[:base_on] })
    redirect_to changes_plan_path(plan[:plan_id]), notice: rebased(result)
  rescue Operations::Base::ParameterError => e
    redirect_to changes_plan_path(plan[:plan_id]), alert: "Couldn't update to today: #{e.message}"
  end

  private

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

  # Today has no period, so only a scenario is priced. Cost shows once a pay
  # band prices something; a scenario that can't be priced keeps its map.
  def cost_hooks(plan, map)
    return {} if map[:scenario_id] == plan[:plan_id]

    marks = Views::Plans::CostMarks.new(cost: read(Operations::TeamPlanning::Cost, scenario_id: map[:scenario_id]), map:)
    marks.priced? ? { unit_marks: marks.unit_marks, summary: Views::Plans::CostStrip.new(marks:) } : {}
  rescue ActiveRecord::RecordNotFound
    {}
  end

  def cost_columns
    return [] unless PayBand.exists?

    costs = read(Operations::TeamPlanning::ScenarioCosts)
    rows = costs[:scenarios].index_by { it[:scenario_id] }
    priced = rows.values.any? { |row| row[:total]&.values_at(:scenario, :baseline)&.any? { it[:native].any? } }
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

  def plan_page(plan, open_tab:, scenarios: read(Operations::TeamPlanning::Scenarios)[:scenarios], body: nil)
    members = read(Operations::TeamPlanning::PlanMembers)[:members]
    Views::Plans::ShowView.new(
      plan:,
      scenarios:,
      members:,
      see_pay: see_pay(members),
      tabs: [ Views::Plans::ShowView::Tab.new(key: :scenarios, label: "Scenarios", href: plan_path(plan[:plan_id])),
              Views::Plans::ShowView::Tab.new(key: :map, label: "Map", href: map_plan_path(plan[:plan_id])),
              Views::Plans::ShowView::Tab.new(key: :timeline, label: "Timeline", href: timeline_plan_path(plan[:plan_id])),
              Views::Plans::ShowView::Tab.new(key: :changes, label: "Changes", href: changes_plan_path(plan[:plan_id])) ],
      open_tab:,
      body:,
      can_edit: can_edit?,
      **layout
    )
  end

  def index_view(error: nil, draft: {})
    Views::Plans::IndexView.new(
      plans: Operations::TeamPlanning::Plans.call(context: pundit_user)[:plans],
      can_create: policy_for(TeamPlanningPlan).create?,
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
    { can_manage_see_pay: policy_for(@plan_record).manage_see_pay?,
      reachable_ids: PlanPolicy.reachable_ids(members.pluck(:person_id)),
      locked_out: PlanPolicy.locked_out?(@plan_record) && !PlanPolicy.frozen?(@plan_record) }
  end

  def can_edit?
    return @can_edit if defined?(@can_edit)

    @can_edit = policy_for(@plan_record).update?
  end

  def layout
    { user: current_user, current_tenant: ActsAsTenant.current_tenant,
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a } }
  end
end
