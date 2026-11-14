# frozen_string_literal: true

# Moves a level up or down one place, from the settings screen's levels panel.
# The form names only the level and the direction; the swap is made against the
# order as it stands now, so a page left open can't undo another admin's move.
class Tenant::OrgGraphSettings::LevelOrdersController < ApplicationController
  include OrgGraphSettingsRedirect

  # PATCH /tenant/org_graph/settings/level_order
  def update
    authorize :org_graph, :edit_taxonomy?

    order = OrgTaxonomyLevel.top_first.pluck(:id)
    from = order.index(params[:level_id].to_s.downcase)
    return back_with_alert("That level no longer exists.") unless from

    to = direction == "up" ? from - 1 : from + 1
    unless to.between?(0, order.size - 1)
      return back_with_alert("#{moved_name} did not move: it is already at the #{direction == 'up' ? 'top' : 'bottom'}.")
    end

    order[from], order[to] = order[to], order[from]
    Operations::OrgGraph::ReorderLevels.call(context: pundit_user, params: { level_ids: order })
    back_with_notice "#{moved_name} moved #{direction}."
  rescue Operations::Base::ParameterError => e
    back_with_refusal "#{moved_name} did not move", e
  end

  private

  def direction = params[:direction] == "down" ? "down" : "up"

  def moved_name
    OrgTaxonomyLevel.find_by(id: params[:level_id].to_s.downcase)&.name || "The level"
  end

  def back_with_alert(alert)
    redirect_to tenant_org_graph_settings_path, alert:, status: :see_other
  end
end
