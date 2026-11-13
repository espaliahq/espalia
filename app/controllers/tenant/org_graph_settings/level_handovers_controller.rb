# frozen_string_literal: true

# Hands a structure level that holds units to an HRIS field, and back, from
# the settings screen. `show` compares and writes nothing; `update` hands the
# level over as that comparison showed it; `destroy` hands it back.
#
# Each unit's call arrives as `calls[<unit id>]` (see
# {Views::Tenant::OrgGraph::Settings::HandoverFrame}) and is split here into
# the matches and resolutions the Operations take.
class Tenant::OrgGraphSettings::LevelHandoversController < ApplicationController
  include HrisFieldReading
  include OrgGraphSettingsRedirect

  before_action :set_level

  # GET /tenant/org_graph/settings/level_handovers/:level_id?field_id=&calls[<unit id>]=
  def show
    authorize :integrations, :hand_over_hris_level?

    render Views::Tenant::OrgGraph::Settings::HandoverFrame.new(level: { id: @level.id, name: @level.name }, **reading)
  end

  # PATCH /tenant/org_graph/settings/level_handovers/:level_id
  def update
    authorize :integrations, :hand_over_hris_level?

    matches, resolutions = split_calls
    Operations::Integrations::HandOverHrisLevel.call(context: pundit_user, params: {
      level_id: @level.id, field_id: params.expect(:field_id), matches:, resolutions:,
      fingerprint: params.expect(:fingerprint),
      confirm_memberships_ended: params[:confirm_memberships_ended].presence&.to_i,
      confirm_units_retired: params[:confirm_units_retired].presence&.to_i
    }.compact)
    back_with_notice "#{@level.name} now comes from #{hris_label}, and its memberships follow the HRIS."
  rescue Operations::Base::ParameterError => e
    back_with_refusal "#{@level.name} was not handed over", e
  end

  # DELETE /tenant/org_graph/settings/level_handovers/:level_id
  def destroy
    authorize :integrations, :hand_over_hris_level?

    Operations::Integrations::HandBackHrisLevel.call(
      context: pundit_user, params: { level_id: @level.id, fingerprint: params.expect(:fingerprint) }
    )
    back_with_notice "#{@level.name} now comes from Espalia. Its units and memberships stay as they are."
  rescue Operations::Base::ParameterError => e
    back_with_refusal "#{@level.name} was not handed back", e
  end

  private

  def set_level
    @level = OrgTaxonomyLevel.find_by(id: params.expect(:level_id).to_s.downcase) or head(:not_found)
  end

  def reading
    return { handback: compare } unless Hris::LevelHandover.espalia?(@level)

    catalogue = hris_catalogue
    field_id = params[:field_id].presence
    return catalogue unless field_id && catalogue[:fields]

    { **catalogue, chosen: field_id, calls:, compared: params.key?(:calls), comparison: compare(field_id) }
  rescue Operations::Base::ParameterError => e
    { **(catalogue || {}), chosen: field_id, problem: e.message.sub(/\A\w+: /, "") }
  end

  def compare(field_id = nil)
    matches, resolutions = split_calls
    Operations::Integrations::HrisLevelHandover.call(
      context: pundit_user, params: { level_id: @level.id, field_id:, matches:, resolutions: }.compact
    )
  end

  # @return [Hash{String => String}]
  def calls
    sent = params[:calls]
    sent.is_a?(ActionController::Parameters) ? sent.permit(*sent.keys).to_h : {}
  end

  # @return [Array(Hash, Hash)] matches (unit id => value key) and resolutions (unit id => unit id or "retire")
  def split_calls
    calls.each_with_object([ {}, {} ]) do |(unit_id, call), (matches, resolutions)|
      kind, value = call.to_s.split(":", 2)
      case kind
      when "match" then matches[unit_id] = value
      when "into" then resolutions[unit_id] = value
      when Hris::LevelHandover::RETIRE then resolutions[unit_id] = Hris::LevelHandover::RETIRE
      end
    end
  end

  def hris_label = HrisConfig.provider_label(ActsAsTenant.current_tenant.hris_config.provider)
end
