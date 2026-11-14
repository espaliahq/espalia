# frozen_string_literal: true

# The HRIS field picker for an empty structure level, with a preview of the
# units a field would make before anyone chooses it. It reads the HRIS and
# writes nothing; choosing goes through {LevelProvidersController}.
#
# Not an MCP tool of its own: the catalogue fills one web form, and the
# preview is integrations_hris_field_preview.
class Tenant::OrgGraphSettings::LevelFieldsController < ApplicationController
  include HrisFieldReading

  # GET /tenant/org_graph/settings/level_fields/:level_id?field_id=<catalogue id>
  def show
    authorize :org_graph, :edit_structure?
    level = OrgTaxonomyLevel.find_by(id: params.expect(:level_id).to_s.downcase) or return head(:not_found)

    render Views::Tenant::OrgGraph::Settings::FieldPickerFrame.new(
      picker: Views::Tenant::OrgGraph::Settings::LevelsPanel.picker(level.id, level.name),
      current: level.provider_field, **hris_catalogue, **hris_field_preview(Integrations::HrisFieldPreview::LEVEL)
    )
  end
end
