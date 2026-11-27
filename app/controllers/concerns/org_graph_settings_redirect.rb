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

  # A unit's structure page sends `back=structure`, so its writes return
  # there, or to the unit once it has no structure left: an owner can't open
  # Settings.
  def landing(anchor)
    return tenant_org_graph_settings_path(anchor:) unless params[:back] == "structure" && params[:structure_unit_id].present?

    unit_id = params[:structure_unit_id].to_s
    return edit_tenant_org_structure_path(unit_id) if OrgTaxonomyLevel.in_structure(unit_id.downcase).exists?

    tenant_org_graph_path(unit: unit_id)
  end
end
