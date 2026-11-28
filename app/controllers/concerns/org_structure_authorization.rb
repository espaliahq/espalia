# frozen_string_literal: true

# Pundit's `authorize` passes no argument to the policy, and the right to
# change a structure turns on whose structure it is.
module OrgStructureAuthorization
  extend ActiveSupport::Concern

  private

  # @param unit [OrgUnit, nil] the declaring unit, nil for the organisation's structure
  # @raise [Pundit::NotAuthorizedError] unless the caller may change that structure
  def authorize_structure_of!(unit)
    authorize :org_graph, :show?
    return if policy(:org_graph).edit_structure_of?(unit)

    raise Pundit::NotAuthorizedError, query: :edit_structure_of?, record: :org_graph, policy: policy(:org_graph)
  end

  # @return [OrgUnit, nil] the live unit `structure_unit_id` names, nil for the organisation's structure
  def structure_unit
    return @structure_unit if defined?(@structure_unit)

    @structure_unit = params[:structure_unit_id].presence && OrgUnit.live.find_by(id: params[:structure_unit_id].to_s.downcase)
  end
end
