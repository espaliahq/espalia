# frozen_string_literal: true

# What the unit drawer's controllers share (#124): the unit, the gate, and
# writes for several people at once. The rest is OrgGraphDrawer's.
module OrgUnitDrawer
  extend ActiveSupport::Concern
  include OrgGraphDrawer
  include OrgGraphComparison

  included do
    before_action :set_unit
  end

  private

  def set_unit
    @unit = OrgUnit.live.find(params[:org_unit_id] || params[:id])
  rescue ActiveRecord::RecordNotFound
    authorize :org_graph, :show_units?
    redirect_to tenant_org_graph_path(**comparison_params), alert: "That unit isn't in the Org Graph."
  end

  # Runs one write per person. A refusal partway says how many were saved
  # before it, since those stay saved.
  #
  # @param person_ids [Array<String>]
  # @yieldparam person_id [String]
  def write_each(person_ids, notice:)
    saved = 0
    write(notice:) do
      person_ids.each { |person_id| yield person_id; saved += 1 }
    rescue *OrgGraphDrawer::FAILURES => e
      raise if saved.zero?

      raise e.class, "Saved #{saved} of #{person_ids.size}. #{readable(e.message)}"
    end
  end

  def drawer_path = edit_tenant_org_unit_path(@unit, on: drawer_on, **comparison_params)

  # The date a drawer step opens with: the one carried in, or today.
  def step_date = params[:on].presence || effective_on || Date.current.iso8601

  # Renders a drawer over the Units view, opened at the unit.
  #
  # @yieldparam overview [OrgGraph::UnitsOverview]
  # @yieldparam rights [OrgGraphPolicy::UnitRights]
  # @yieldreturn [Phlex::SGML] the drawer
  def render_drawer
    overview = OrgGraph::UnitsOverview.new(selected_unit_id: @unit.id)
    render Views::Tenant::OrgGraph::ShowView.new(
      overview:,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a },
      drawer: yield(overview, OrgGraphPolicy::UnitRights.new(policy(:org_graph), @unit, overview)),
      **comparison_slots(unit_id: @unit.id)
    )
  end
end
