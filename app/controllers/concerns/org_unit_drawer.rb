# frozen_string_literal: true

# What the unit drawer's controllers share (#124): the unit, the gate, and one
# way to run a write. A write that fails comes back to the drawer with the
# reason, which for a refusal names who may make the change.
module OrgUnitDrawer
  extend ActiveSupport::Concern

  # What every drawer write can raise: a refusal, a bad parameter, or a guard
  # in the aggregate such as another provider holding the fact.
  FAILURES = [ OrgGraph::Authorization::Refused, Operations::Base::ParameterError, RuntimeError ].freeze

  included do
    before_action :set_unit
  end

  private

  def set_unit
    @unit = OrgUnit.live.find(params[:org_unit_id] || params[:id])
  rescue ActiveRecord::RecordNotFound
    authorize :org_graph, :show_units?
    redirect_to tenant_org_graph_path, alert: "That unit isn't in the Org Graph."
  end

  # Runs one or more operations, then returns to the drawer.
  #
  # @param notice [String]
  # @yield calls the operations; an error stops at the first failure
  def write(notice:, status: :found)
    yield
    redirect_to drawer_path, status:, notice:
  rescue *FAILURES => e
    redirect_to drawer_path, status:, flash: { drawer_alert: readable(e.message) }
  end

  # A provider guard names the provider by its key ("hibob supplies this unit").
  def readable(message)
    message.sub(/\A(\w+) supplies/) { "#{HrisConfig.provider_label(Regexp.last_match(1))} supplies" }.upcase_first
  end

  # The date a change takes effect, kept across the redirect so a run of
  # changes back-dated to one day needs choosing once.
  def effective_on = params[:effective_on].presence

  def drawer_path
    on = effective_on unless effective_on == Date.current.iso8601
    edit_tenant_org_unit_path(@unit, on:)
  end

  def with_date(params) = effective_on ? params.merge(effective_on:) : params
end
