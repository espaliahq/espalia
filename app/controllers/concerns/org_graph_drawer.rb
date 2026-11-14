# frozen_string_literal: true

# What the unit and person drawers share (#136): one way to run a write and
# come back to the drawer, the date carried across the redirect, and the
# allocation parse. The including concern supplies `drawer_path`.
module OrgGraphDrawer
  extend ActiveSupport::Concern

  # What every drawer write can raise: a refusal, a bad parameter, or a guard
  # in the aggregate such as another provider holding the fact.
  FAILURES = [ OrgGraph::Authorization::Refused, Operations::Base::ParameterError, RuntimeError ].freeze

  private

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

  # The `on` a drawer path carries: none for today.
  def drawer_on = (effective_on unless effective_on == Date.current.iso8601)

  def with_date(params) = effective_on ? params.merge(effective_on:) : params

  # The form asks for a percentage; the Org Graph stores a fraction.
  def allocation
    percent = params[:allocation].presence or return
    Float(percent) / 100
  rescue ArgumentError
    raise Operations::Base::ParameterError, "Allocation must be a number, got #{percent.inspect}"
  end
end
