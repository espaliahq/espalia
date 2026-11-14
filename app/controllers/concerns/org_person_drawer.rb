# frozen_string_literal: true

# What the person drawer's controllers share (#132): the person, and one way
# to run a write that comes back to the drawer. A refusal comes back with its
# reason, which names who may make the change.
module OrgPersonDrawer
  extend ActiveSupport::Concern
  include OrgGraphComparison

  included do
    before_action :set_person
  end

  private

  def set_person
    @person = Person.find(params[:org_person_id] || params[:id])
  rescue ActiveRecord::RecordNotFound
    authorize :org_graph, :show_units?
    redirect_to tenant_org_graph_path, alert: "That person isn't in this workspace."
  end

  # @param notice [String]
  # @yield calls the operation
  def write(notice:, status: :found)
    yield
    redirect_to drawer_path, status:, notice:
  rescue *OrgUnitDrawer::FAILURES => e
    redirect_to drawer_path, status:, flash: { drawer_alert: readable(e.message) }
  end

  # A provider guard names the provider by its key ("hibob supplies this unit").
  def readable(message)
    message.sub(/\A(\w+) supplies/) { "#{HrisConfig.provider_label(Regexp.last_match(1))} supplies" }.upcase_first
  end

  # The date a change takes effect, kept across the redirect.
  def effective_on = params[:effective_on].presence

  # The unit open behind the drawer, kept so closing returns to it.
  def unit_param = params[:unit].presence

  # "edit" when the person was opened from the unit drawer, so closing reopens it.
  def back_param = ("edit" if params[:back] == "edit" && unit_param)

  def close_path = back_param ? edit_tenant_org_unit_path(unit_param, **comparison_params) : tenant_org_graph_path(unit: unit_param, **comparison_params)

  def drawer_path
    on = effective_on unless effective_on == Date.current.iso8601
    tenant_org_person_path(@person, on:, unit: unit_param, back: back_param, **comparison_params)
  end

  def with_date(params) = effective_on ? params.merge(effective_on:) : params
end
