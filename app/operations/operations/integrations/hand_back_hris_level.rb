# frozen_string_literal: true

# Hands a structure level back from the HRIS to Espalia (#117).
#
# Approval is :in_app, with the fingerprint integrations_hris_level_handover
# gave, as for handing a level over.
class Operations::Integrations::HandBackHrisLevel < Operations::Base
  include Operations::Integrations::HrisLevelHandoverSupport

  description "Hand an Org Graph structure level back from the HRIS to Espalia, so people edit its units " \
              "here again. Pass the fingerprint integrations_hris_level_handover gave for the level. Units " \
              "and memberships stay as they are; successions and retirements made by the handover stand."
  category :write
  approval :in_app

  parameter :level_id, String, required: true, allow_blank: false
  parameter :fingerprint, String, required: true, allow_blank: false

  def policy_check
    authorize :integrations, :show?
  end

  # @return [Hash] what was handed back
  # @raise [Operations::Base::ParameterError]
  def perform
    handover = self.handover
    refusals { handback_payload(handover.hand_back!(fingerprint: params[:fingerprint], actor: context)) }
  end
end
