# frozen_string_literal: true

# Saves where one unit type can sit, from its row in the settings screen's
# unit types panel: the types it can sit under, and whether it can sit at the
# top. The form posts the whole list, which replaces the type's rules, so it
# also carries the rules it was drawn with: a page left open can't undo
# another admin's change.
class Tenant::OrgGraphSettings::KindParentsController < ApplicationController
  include OrgGraphSettingsRedirect

  # PATCH /tenant/org_graph/settings/kind_parents/:level_id
  def update
    authorize :org_graph, :edit_taxonomy?
    result = ActiveRecord::Base.transaction do
      ::OrgGraph::Repository.new.lock_structure # so no save lands between the comparison and this write
      next if changed_since_drawn?

      Operations::OrgGraph::SetKindParents.call(
        context: pundit_user,
        params: { level_id: params[:level_id].to_s, parent_ids: Array(params[:parent_ids]).map(&:to_s), top: params[:top] == "1", **in_structure }
      )
    end
    return back_with_alert(changed_meanwhile) unless result

    back_with_notice "Saved where #{result[:name]} can sit.", anchor:
  rescue Operations::Base::ParameterError => e
    back_with_refusal "#{type_name}'s place did not change", e, anchor:
  end

  private

  def changed_since_drawn?
    return false unless params.key?(:was_top)

    now = OrgTaxonomyLevel.rules_by_id(OrgTaxonomyLevel.in_structure(params[:structure_unit_id].presence).to_a)[params[:level_id].to_s.downcase]
    now && [ now[:parent_ids].sort, now[:top] ] != [ Array(params[:was_parent_ids]).map(&:to_s).sort, params[:was_top] == "1" ]
  end

  def changed_meanwhile
    "Someone changed where #{type_name} can sit while this page was open, so yours wasn't saved. " \
      "The boxes now show their change: tick yours again and save."
  end

  def back_with_alert(alert)
    redirect_to tenant_org_graph_settings_path(anchor:), alert:, status: :see_other
  end

  def in_structure = params[:structure_unit_id].present? ? { structure_unit_id: params[:structure_unit_id].to_s } : {}

  def anchor = params[:structure_unit_id].presence && Views::Tenant::OrgGraph::Settings::LevelsPanel.anchor(params[:structure_unit_id])

  def type_name = OrgTaxonomyLevel.find_by(id: params[:level_id].to_s.downcase)&.name || "The unit type"
end
