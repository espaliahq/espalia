# frozen_string_literal: true

# Compares a structure level with the HRIS field it would come from, before
# handing it over (#117), or says what handing it back would keep. A read: it
# asks the HRIS for that one field and writes nothing.
class Operations::Integrations::HrisLevelHandover < Operations::Base
  include Operations::Integrations::HrisLevelHandoverSupport

  description "Compare an Org Graph structure level with an HRIS field before handing the level to the HRIS. " \
              "Each unit gets a suggested value by name, never a match: pass the values a person confirmed " \
              "in matches (unit id => value key), and for each unit left over a resolution (unit id => a " \
              "matched unit's id to succeed into, or \"retire\"). Returns the units, the field's values, how " \
              "many people differ, are blank, were added by hand or would join, the units still unresolved, " \
              "the counts the brake weighs, and a fingerprint integrations_hand_over_hris_level needs. For a " \
              "level the HRIS already supplies, says what handing it back would keep, with its fingerprint. " \
              "Reads the HRIS live; writes nothing."
  category :read
  approval :none

  parameter :level_id, String, required: true, allow_blank: false
  parameter :field_id, String
  parameter :matches, Hash, schema: MAP_SCHEMA
  parameter :resolutions, Hash, schema: MAP_SCHEMA

  def policy_check
    authorize :integrations, :show?
  end

  # @return [Hash]
  # @raise [Operations::Base::ParameterError]
  def perform
    handover = self.handover
    refusals do
      next handback_payload(handover.compare_handback) unless handover.espalia?
      raise ParameterError, "field_id: required to hand a level to the HRIS" if params[:field_id].blank?

      comparison_payload(handover.compare(field_id: params[:field_id], matches: params[:matches] || {},
                                          resolutions: params[:resolutions] || {}))
    end
  end
end
