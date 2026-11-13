# frozen_string_literal: true

# The HRIS field picker for a fact read from a field of the tenant's choosing,
# and the preview of a field before anyone chooses it. It reads the HRIS and
# writes nothing; choosing goes through {FactProvidersController}.
#
# Not an MCP tool of its own: the catalogue fills one web form, and the
# preview is integrations_hris_field_preview.
class Tenant::OrgGraphSettings::FactFieldsController < ApplicationController
  MAPPABLE = OrgGraph::StructureAggregate::MAPPABLE_FIELDS

  # GET /tenant/org_graph/settings/fact_fields/:fact?field_id=<catalogue id>
  def show
    authorize :org_graph, :edit_structure?
    fact = params.expect(:fact)
    return head(:not_found) unless MAPPABLE.key?(fact)

    part = MAPPABLE.fetch(fact).first
    render Views::Tenant::OrgGraph::Settings::FactFieldFrame.new(
      fact:, part:, current: OrgFactProvider.find_by(fact:)&.fields&.dig(part), chosen: params[:field_id].presence,
      **catalogue, **preview(part)
    )
  end

  private

  def tenant = ActsAsTenant.current_tenant

  # @return [Hash] `fields:` or `problem:`
  def catalogue
    { fields: Hris::BaseAdapter.for(tenant).field_catalogue }
  rescue Hris::Hibob::Errors::AuthenticationError
    { problem: "The HRIS refused the stored credentials." }
  rescue Hris::Hibob::Errors::RateLimitError
    { problem: "The HRIS is limiting requests just now. Reload the page in a minute." }
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { tenant_id: tenant.id })
    { problem: "The HRIS did not answer as expected. Reload the page to try again." }
  end

  # @return [Hash] `preview:` or `preview_problem:`, or nothing before a field is chosen
  def preview(part)
    return {} if params[:field_id].blank?

    { preview: Operations::Integrations::HrisFieldPreview.call(
      context: pundit_user, params: { field_id: params[:field_id].to_s, target: part }
    ) }
  rescue Operations::Base::ParameterError => e
    { preview_problem: e.message }
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { tenant_id: tenant.id })
    { preview_problem: "The HRIS did not answer as expected. Try again in a minute." }
  end
end
