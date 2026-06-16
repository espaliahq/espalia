# frozen_string_literal: true

# Archives a capability category from the explorer's edit-mode category-header
# kebab, submitted by the archive-category modal. A category carries no ratings,
# so there is no migration mapping — just an optional reason. The aggregate
# refuses if the category still holds active capabilities.
#
# Restricted to edit-rights holders via FrameworkPolicy#archive_category?.
class Frameworks::CategoryArchivesController < ApplicationController
  before_action :set_framework
  before_action :set_category

  # POST /frameworks/:framework_id/category_archives
  def create
    authorize @framework, :archive_category?

    Operations::Frameworks::ArchiveCategory.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        category_id: @category.category_id,
        reason: archive_params[:reason].presence
      }
    )

    redirect_to edit_framework_path(@framework.framework_id),
                notice: "Archived “#{@category.name}”."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to edit_framework_path(@framework.framework_id), alert: e.message
  end

  private

  def archive_params
    @archive_params ||= params.expect(archive: [ :category_id, :reason ])
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end

  # Resolve from the explorer graph (NOT the published read model) so a category
  # added in the current draft can be archived too. The graph is per-framework,
  # so finding the id in it scopes to the authorized framework.
  def set_category
    graph = Frameworks::ExplorerGraph.load(@framework.framework_id) ||
            Frameworks::ExplorerGraph.rebuild(@framework.framework_id)
    @category = graph.capability_categories
      .find { |c| c.category_id == archive_params[:category_id] }
    redirect_to edit_framework_path(@framework.framework_id) unless @category
  end
end
