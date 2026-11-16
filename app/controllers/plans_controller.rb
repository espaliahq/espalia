# frozen_string_literal: true

# Team Planning's plans index, plan page (#226) and map (#227). Every read goes through
# the Team Planning Operations, as the MCP tools do, so a plan someone isn't
# in is a 404 here and "No such plan" there.
class PlansController < ApplicationController
  around_action ->(_, action) { TeamPlanning::Resolution.reusing(&action) }, only: %i[show map budget]

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
    render plan_page(plan, scenarios:, open_tab: :timeline,
                           body: Views::Plans::Timeline.new(timeline:, scenarios:, step: params[:step].to_i, can_edit: can_edit?))
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
    render plan_page(plan, scenarios:, open_tab: :checks, body: tab)
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
            Views::Plans::BudgetTab.new(plan:, scenarios:, lines:, budget: read(Operations::TeamPlanning::Budget, scenario_id:),
                                        funding: read(Operations::TeamPlanning::Funding, scenario_id:),
                                        map: read(Operations::TeamPlanning::ScenarioMap, scenario_id:))
    end
    render plan_page(plan, scenarios:, open_tab: :budget, body: tab)
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
    return [] unless PayBand.exists?

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
      panel_open: Views::Plans::ShowView.panel_open?(
        choice: params[Views::Plans::ShowView::PANEL_URL_KEY].presence || cookies[Views::Plans::ShowView::PANEL_COOKIE],
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
