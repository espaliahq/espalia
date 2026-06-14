# frozen_string_literal: true

# Records or edits a capability migration mapping from the publish-review
# screen — the owner/editor validating (and possibly overriding) the as-we-go
# choices before publishing. Restricted to owner/editor via
# FrameworkPolicy#define_migration_mapping?.
class Frameworks::MigrationMappingsController < ApplicationController
  before_action :set_framework

  # POST /frameworks/:framework_id/migration_mappings
  def create
    authorize @framework, :define_migration_mapping?
    attrs = params.expect(migration_mapping: [ :from_stable_id, :mapping_type, :to_stable_id, :mapping_id ])

    Operations::Frameworks::DefineMigrationMapping.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        from_stable_id: attrs[:from_stable_id],
        mapping_type: attrs[:mapping_type],
        to_stable_id: attrs[:to_stable_id].presence,
        mapping_id: attrs[:mapping_id].presence
      }
    )

    redirect_to new_framework_publication_path(@framework.framework_id), notice: "Mapping saved."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to new_framework_publication_path(@framework.framework_id), alert: e.message
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end
end
