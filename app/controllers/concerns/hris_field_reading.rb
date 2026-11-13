# frozen_string_literal: true

# Reads the HRIS's field catalogue, and a preview of one field, for the Org
# Graph settings' field pickers. A failure becomes a sentence for the frame.
module HrisFieldReading
  extend ActiveSupport::Concern

  private

  # @return [Hash] `fields:` or `problem:`
  def hris_catalogue
    { fields: Hris::BaseAdapter.for(ActsAsTenant.current_tenant).field_catalogue }
  rescue Hris::Hibob::Errors::AuthenticationError
    { problem: "The HRIS refused the stored credentials." }
  rescue Hris::Hibob::Errors::RateLimitError
    { problem: "The HRIS is limiting requests just now. Reload the page in a minute." }
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { tenant_id: ActsAsTenant.current_tenant&.id })
    { problem: "The HRIS did not answer as expected. Reload the page to try again." }
  end

  # @param target [String] "level", or a fact's part
  # @return [Hash] `chosen:` with `preview:` or `preview_problem:`, or nothing before a field is chosen
  def hris_field_preview(target)
    field_id = params[:field_id].presence or return {}

    { chosen: field_id, preview: Operations::Integrations::HrisFieldPreview.call(
      context: pundit_user, params: { field_id:, target: }
    ) }
  rescue Operations::Base::ParameterError => e
    { chosen: field_id, preview_problem: e.message }
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { tenant_id: ActsAsTenant.current_tenant&.id })
    { chosen: field_id, preview_problem: "The HRIS did not answer as expected. Try again in a minute." }
  end
end
