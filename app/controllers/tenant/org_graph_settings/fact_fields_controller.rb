# frozen_string_literal: true

# The HRIS field picker for a fact read from a field of the tenant's choosing,
# with a preview of a field before anyone chooses it. It reads the HRIS and
# writes nothing; choosing goes through {FactProvidersController}.
#
# Not an MCP tool of its own: the catalogue fills one web form, and the
# preview is integrations_hris_field_preview.
class Tenant::OrgGraphSettings::FactFieldsController < ApplicationController
  include HrisFieldReading

  MAPPABLE = OrgGraph::StructureAggregate::MAPPABLE_FIELDS

  # GET /tenant/org_graph/settings/fact_fields/:fact?field_id=<catalogue id>
  def show
    authorize :org_graph, :edit_structure?
    fact = params.expect(:fact)
    return head(:not_found) unless MAPPABLE.key?(fact)

    part = MAPPABLE.fetch(fact).first
    render Views::Tenant::OrgGraph::Settings::FieldPickerFrame.new(
      picker: Views::Tenant::OrgGraph::Settings::SourcesPanel.picker(fact, part),
      current: OrgFactProvider.find_by(fact:)&.fields&.dig(part), **hris_catalogue, **hris_field_preview(part)
    )
  end
end
