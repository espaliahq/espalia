# frozen_string_literal: true

# Hands a structure level Espalia holds to an HRIS field (#117), as the
# comparison an admin read showed it.
#
# Approval is :in_app, and the fingerprint is required: the switch retires
# units and ends memberships, so an agent cannot make it on a comparison
# nobody read.
class Operations::Integrations::HandOverHrisLevel < Operations::Base
  include Operations::Integrations::HrisLevelHandoverSupport

  description "Hand an Org Graph structure level to an HRIS field, as integrations_hris_level_handover " \
              "compared it. Pass the same matches and resolutions and that comparison's fingerprint; a " \
              "changed HRIS or level refuses it. In one change it records the field as the level's source, " \
              "gives each matched unit its value, succeeds or retires every other unit, and moves memberships " \
              "to agree with the HRIS. When the comparison is over the brake, pass the memberships it ends " \
              "and the units it retires as confirm_memberships_ended and confirm_units_retired, exactly as " \
              "the comparison gave them."
  category :write
  approval :in_app

  parameter :level_id, String, required: true, allow_blank: false
  parameter :field_id, String, required: true, allow_blank: false
  parameter :matches, Hash, required: true, schema: MAP_SCHEMA
  parameter :resolutions, Hash, schema: MAP_SCHEMA
  parameter :fingerprint, String, required: true, allow_blank: false
  parameter :confirm_memberships_ended, Integer
  parameter :confirm_units_retired, Integer

  def policy_check
    authorize :integrations, :hand_over_hris_level?
  end

  # @return [Hash] the comparison the handover wrote
  # @raise [Operations::Base::ParameterError]
  def perform
    handover = self.handover
    refusals do
      comparison_payload(handover.hand_over!(
        field_id: params[:field_id], matches: params[:matches], resolutions: params[:resolutions] || {},
        fingerprint: params[:fingerprint], actor: context,
        confirm: { memberships_ended: params[:confirm_memberships_ended], units_retired: params[:confirm_units_retired] }
      ))
    end
  end
end
