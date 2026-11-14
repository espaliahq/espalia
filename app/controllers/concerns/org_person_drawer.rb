# frozen_string_literal: true

# What the person drawer's controllers share (#132): the person, and the unit
# open behind the drawer. Writes are OrgGraphDrawer's.
module OrgPersonDrawer
  extend ActiveSupport::Concern
  include OrgGraphDrawer

  included do
    before_action :set_person
  end

  private

  def set_person
    @person = Person.find(params[:org_person_id] || params[:id])
  rescue ActiveRecord::RecordNotFound
    authorize :org_graph, :show_units?
    redirect_to tenant_org_graph_path(unit: unit_param, **comparison_params), alert: "That person isn't in this workspace."
  end

  # The unit open behind the drawer, kept so closing returns to it.
  def unit_param = params[:unit].presence

  # "edit" when the person was opened from the unit drawer, so closing reopens it.
  def back_param = ("edit" if params[:back] == "edit" && unit_param)

  def close_path = back_param ? edit_tenant_org_unit_path(unit_param, **comparison_params) : tenant_org_graph_path(unit: unit_param, **comparison_params)

  def drawer_path = tenant_org_person_path(@person, on: drawer_on, unit: unit_param, back: back_param, **comparison_params)
end
