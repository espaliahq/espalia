# frozen_string_literal: true

# How the Org Graph settings panels answer a write: back to the screen, with
# what changed or why it didn't.
module OrgGraphSettingsRedirect
  extend ActiveSupport::Concern

  private

  def back_with_notice(notice, anchor: nil)
    redirect_to landing(anchor), notice:, status: :see_other
  end

  # Drops the parameter name an Operation's refusal starts with, which reads
  # as noise on a form that names its own fields.
  #
  # @param lead [String] what couldn't be done, e.g. "The editor could not be added"
  # @param error [Operations::Base::ParameterError]
  def back_with_refusal(lead, error, anchor: nil)
    redirect_to landing(anchor), alert: "#{lead}: #{error.message.sub(/\A\w+: /, '')}", status: :see_other
  end

  # A unit's structure page sends `back=structure`, so its writes return there.
  def landing(anchor)
    return edit_tenant_org_structure_path(params[:structure_unit_id]) if params[:back] == "structure" && params[:structure_unit_id].present?

    tenant_org_graph_settings_path(anchor:)
  end
end
