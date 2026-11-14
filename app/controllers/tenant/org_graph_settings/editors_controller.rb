# frozen_string_literal: true

# Adds and removes Org Graph editors from the settings screen's "Who may
# edit" panel.
class Tenant::OrgGraphSettings::EditorsController < ApplicationController
  include OrgGraphSettingsRedirect

  # POST /tenant/org_graph/settings/editors
  def create
    authorize ActsAsTenant.current_tenant, :manage_org_graph_editors?, policy_class: TenantPolicy

    Operations::OrgGraph::AddEditor.call(context: pundit_user, params: { person_id: params.expect(:person_id) })
    back_with_notice "#{person_name} may now edit the Org Graph."
  rescue Operations::Base::ParameterError => e
    back_with_refusal "The editor could not be added", e
  end

  # DELETE /tenant/org_graph/settings/editors/:person_id
  def destroy
    authorize ActsAsTenant.current_tenant, :manage_org_graph_editors?, policy_class: TenantPolicy

    Operations::OrgGraph::RemoveEditor.call(context: pundit_user, params: { person_id: params.expect(:person_id) })
    back_with_notice "#{person_name} may no longer edit the Org Graph."
  rescue Operations::Base::ParameterError => e
    back_with_refusal "The editor could not be removed", e
  end

  private

  def person_name
    Person.find_by(id: params[:person_id])&.name || "That person"
  end
end
