# frozen_string_literal: true

# Saves the publish-review screen's migration mappings — every retiring
# capability's row in one submit, so choosing a mapping on one row never
# costs the unsaved choices on the others (the per-row save it replaces
# reloaded the page and dropped them, #399). The rows go through
# {Operations::Frameworks::DefineMigrationMappings}, which saves them
# atomically, skips unchanged rows and reports the ones still missing a
# survivor. Restricted to owner/editor via
# FrameworkPolicy#define_migration_mapping?.
class Frameworks::MigrationMappingsController < ApplicationController
  before_action :set_framework

  # POST /frameworks/:framework_id/migration_mappings
  def create
    authorize @framework, :define_migration_mapping?

    result = Operations::Frameworks::DefineMigrationMappings.call(
      context: pundit_user,
      params: { framework_id: @framework.framework_id, mappings: mapping_rows }
    )

    redirect_to new_framework_publication_path(@framework.framework_id), flash: outcome_flash(result)
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to new_framework_publication_path(@framework.framework_id), alert: e.message
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end

  # The review form posts `migration_mappings[<index>][...]`, which Rails
  # parses as an index-keyed hash of rows.
  #
  # @return [Array<Hash>]
  def mapping_rows
    rows = params.expect(migration_mappings: [ [ :from_stable_id, :mapping_type, :to_stable_id, :mapping_id ] ])
    rows = rows.values if rows.respond_to?(:values)
    rows.map(&:to_h)
  end

  def outcome_flash(result)
    saved = result[:saved]
    notice = saved.zero? ? "No mapping changes to save." : "Saved #{saved} #{'mapping'.pluralize(saved)}."
    return { notice: notice } if result[:incomplete].empty?

    { notice: notice, alert: "Still needs a survivor: #{result[:incomplete].to_sentence}." }
  end
end
