# frozen_string_literal: true

# What an HRIS field would give as a level or a fact, before anyone chooses it
# (#107). The settings screen (6.9) hosts the frame; a plain visit gets it on
# a page of its own. It reads the HRIS live and writes nothing.
class Tenant::HrisFieldPreviewsController < ApplicationController
  # GET /tenant/integrations/hris/field_preview?field_id=<catalogue id>&target=<level|cost_centre|country>
  def show
    authorize :integrations, :show?

    frame = Views::Integrations::HrisFieldPreviewFrame.new(target: params[:target].to_s, **preview)
    if turbo_frame_request?
      render frame
    else
      render Views::Integrations::HrisFieldPreviewView.new(
        frame:, user: current_user, current_tenant: ActsAsTenant.current_tenant,
        tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a }
      )
    end
  end

  private

  # @return [Hash] `preview:` or `problem:` for the frame
  def preview
    result = Operations::Integrations::HrisFieldPreview.call(
      context: pundit_user, params: { field_id: params[:field_id].to_s, target: params[:target].to_s }
    )
    { preview: result }
  rescue Operations::Base::ParameterError => e
    { problem: e.message }
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { tenant_id: ActsAsTenant.current_tenant&.id })
    { problem: "The HRIS did not answer as expected. Try again in a minute." }
  end
end
