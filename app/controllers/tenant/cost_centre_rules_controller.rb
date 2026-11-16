# frozen_string_literal: true

# The tenant's cost-centre entries ([#387](https://github.com/espaliahq/espalia/issues/387)):
# an ordered list where the last entry to match a seat names its cost centre,
# kept as the tenant's default for the cost_centre planning rule. Tenant
# admins only. Entries have no ids, so each is addressed by its place, and
# every write carries the version of the list the page showed: a list
# another admin has changed since is refused rather than overwritten.
class Tenant::CostCentreRulesController < ApplicationController
  KIND = TeamPlanning::RuleKinds::CostCentre
  FIELDS = %i[unit_id reach level_ordinal location cost_centre].freeze

  # GET /tenant/cost_centre_rules
  def index
    authorize_rules
    render_index
  end

  # POST /tenant/cost_centre_rules
  def create
    authorize_rules
    return list_changed unless current?

    save(entries + [ entry ])
    redirect_to tenant_cost_centre_rules_path, notice: "Entry added for #{entry["cost_centre"].to_s.squish} at #{entries.size + 1} in the list.",
                                               status: :see_other
  rescue Operations::Base::ParameterError => e
    flash.now[:alert] = "The entry could not be added: #{e.message}."
    render_index(draft: form_params, status: :unprocessable_content)
  end

  # GET /tenant/cost_centre_rules/:id/edit
  def edit
    authorize_rules
    return list_changed unless current? && place && entries[place]

    render_edit(Views::Tenant::CostCentreRules::EntryFields.form_values(entries[place]))
  end

  # PATCH /tenant/cost_centre_rules/:id
  def update
    authorize_rules
    return list_changed unless current? && place && entries[place]

    save(entries.dup.tap { it[place] = entry })
    redirect_to tenant_cost_centre_rules_path, notice: "Entry #{place + 1} changed.", status: :see_other
  rescue Operations::Base::ParameterError => e
    flash.now[:alert] = "The entry could not be changed: #{e.message}."
    render_edit(form_params, status: :unprocessable_content)
  end

  # DELETE /tenant/cost_centre_rules/:id
  def destroy
    authorize_rules
    return list_changed unless current? && place && entries[place]

    save(entries.dup.tap { it.delete_at(place) })
    redirect_to tenant_cost_centre_rules_path, notice: "Entry #{place + 1} removed.", status: :see_other
  end

  # PATCH /tenant/cost_centre_rules/reorder
  #
  # One entry up or down a place, from its buttons, or the whole list in a
  # new order, from a drag. Each entry is named by its place.
  def reorder
    authorize_rules
    order = new_order
    return list_changed unless current? && order

    save(order.map { entries[it] })
    redirect_to tenant_cost_centre_rules_path, notice: reorder_notice(order), status: :see_other
  end

  private

  def authorize_rules
    authorize ActsAsTenant.current_tenant, :manage_planning_rules?, policy_class: TenantPolicy
  end

  # @return [Hash] the cost_centre rule as tenants_planning_rules lists it
  def rule
    @rule ||= Operations::Tenants::PlanningRules.call(context: pundit_user, params: {})[:planning_rules].find { it[:rule] == KIND.rule_name }
  end

  def entries = @entries ||= KIND.entries(rule[:tenant_default] || rule[:built_in_default])

  def current? = params[:version] == Views::Tenant::CostCentreRules::EntryFields.version(entries)

  # @return [Integer, nil] the entry's index, nil for an id that names no place
  def place = (params[:id].to_i - 1 if params[:id].to_s.match?(/\A[1-9]\d*\z/))

  def save(list)
    Operations::Tenants::SetPlanningRule.call(context: pundit_user, params: { rule: KIND.rule_name, value: { "entries" => list } })
  end

  # @return [Array<Integer>, nil] every entry's index in the new order; nil when the move can't be made
  def new_order
    size = entries.size
    return Array(params[:entry_ids]).map { it.to_i - 1 }.then { it.sort == (0...size).to_a ? it : nil } if params.key?(:entry_ids)

    index = params[:entry].to_i - 1
    other = params[:direction] == "up" ? index - 1 : index + 1
    return unless index.between?(0, size - 1) && other.between?(0, size - 1)

    (0...size).to_a.tap { it[index], it[other] = it[other], it[index] }
  end

  def reorder_notice(order)
    return "Saved the new order." unless params.key?(:entry)

    moved = order.index(params[:entry].to_i - 1)
    "Moved the entry for #{entries[order[moved]]['cost_centre']} to #{moved + 1} in the list."
  end

  # The page was out of date: an entry was added, changed, removed or moved since it loaded.
  def list_changed
    redirect_to tenant_cost_centre_rules_path, alert: "The list changed since you opened it, so nothing was saved. Here it is as it stands.",
                                               status: :see_other
  end

  def form_params = @form_params ||= params.expect(entry: FIELDS).to_h.symbolize_keys

  # "family:<id>" or "role:<id>" from the Who picker.
  def entry
    kind, id = form_params[:reach].to_s.split(":", 2)
    { "unit_id" => form_params[:unit_id], "role_id" => (id if kind == "role"), "role_family_id" => (id if kind == "family"),
      "level_ordinal" => form_params[:level_ordinal], "location" => form_params[:location],
      "cost_centre" => form_params[:cost_centre] }.compact_blank
  end

  def render_index(draft: {}, status: :ok)
    render Views::Tenant::CostCentreRules::IndexView.new(
      entries:, shadowed: shadowed, rule:, choices:, draft:, **admin_shell
    ), status:
  end

  def render_edit(values, status: :ok)
    render Views::Tenant::CostCentreRules::EditView.new(place:, values:, version: params[:version], choices:, **admin_shell), status:
  end

  def choices
    @choices ||= Views::Tenant::CostCentreRules::EntryFields::Choices.from(
      units: OrgUnit.order(:name).to_a,
      roles: FrameworkState::Role.includes(:levels, :role_family).order(:name).to_a,
      countries: PayBand.known_countries
    )
  end

  def admin_shell
    { user: current_user, current_tenant: ActsAsTenant.current_tenant,
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a } }
  end

  def shadowed
    parents = choices.units.to_h { [ it.id, it.parent_id ] }
    chain = lambda do |unit_id|
      [ unit_id ].tap { |up| up << parents[up.last] while parents[up.last] && up.exclude?(parents[up.last]) }
    end
    KIND.shadowed({ "entries" => entries }, families: choices.roles.to_h { [ it.role_id, it.role_family_id ] }, chains: chain).to_set
  end
end
