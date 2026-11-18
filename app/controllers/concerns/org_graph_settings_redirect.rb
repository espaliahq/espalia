# frozen_string_literal: true

# How the Org Graph settings panels answer a write: back to the screen, with
# what changed or why it didn't.
module OrgGraphSettingsRedirect
  extend ActiveSupport::Concern

  private

  def back_with_notice(notice, anchor: nil)
    redirect_to tenant_org_graph_settings_path(anchor:), notice:, status: :see_other
  end

  # Drops the parameter name an Operation's refusal starts with, which reads
  # as noise on a form that names its own fields.
  #
  # @param lead [String] what couldn't be done, e.g. "The editor could not be added"
  # @param error [Operations::Base::ParameterError]
  def back_with_refusal(lead, error, anchor: nil)
    redirect_to tenant_org_graph_settings_path(anchor:), alert: "#{lead}: #{error.message.sub(/\A\w+: /, '')}", status: :see_other
  end
end
