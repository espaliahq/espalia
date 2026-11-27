# frozen_string_literal: true

# A unit's own structure on a page of its own ([#537](https://github.com/espaliahq/espalia/issues/537)),
# so the owner who may change it needn't reach Settings: its unit types, and
# where each can sit. The panel's writes land back here.
class Tenant::OrgStructuresController < ApplicationController
  include OrgStructureAuthorization

  # GET /tenant/org_graph/structures/:unit_id/edit
  def edit
    unit = OrgUnit.live.find_by(id: params[:unit_id].to_s.downcase)
    authorize_structure_of!(unit)
    structure = Operations::OrgGraph::UnitStructure.call(context: pundit_user, params: { unit_id: unit.id })
    unless structure[:declares]
      return redirect_to tenant_org_graph_path(unit: unit.id), alert: "#{unit.name} has no structure of its own to change."
    end

    render Views::Tenant::OrgGraph::StructureEditView.new(
      structure:, user: current_user, current_tenant: ActsAsTenant.current_tenant,
      viewer: OrgGraphPolicy::Viewer.new(policy(:org_graph)), tenants: tenants_for_user
    )
  end

  private

  # @return [Array<Tenant>]
  def tenants_for_user
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
