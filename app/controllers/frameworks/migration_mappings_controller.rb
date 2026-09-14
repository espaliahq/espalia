# frozen_string_literal: true

# Saves the publish-review screen's migration mappings — every retiring
# capability's row in one submit, so choosing a mapping on one row never costs
# the unsaved choices on the others (the per-row save it replaces reloaded the
# page and dropped them). Each changed row runs through
# {Operations::Frameworks::DefineMigrationMapping}; unchanged rows emit no
# event, and rows still missing a survivor are left unsaved and named in the
# flash rather than blocking the rest. Restricted to owner/editor via
# FrameworkPolicy#define_migration_mapping?.
class Frameworks::MigrationMappingsController < ApplicationController
  before_action :set_framework

  # POST /frameworks/:framework_id/migration_mappings
  def create
    authorize @framework, :define_migration_mapping?
    rows = mapping_rows

    saved = 0
    incomplete = []
    rows.each do |row|
      next if unchanged?(row)

      if survivor_required?(row) && row[:to_stable_id].blank?
        incomplete << row[:name].presence || "a capability"
        next
      end

      Operations::Frameworks::DefineMigrationMapping.call(
        context: pundit_user,
        params: {
          framework_id: @framework.framework_id,
          from_stable_id: row[:from_stable_id],
          mapping_type: row[:mapping_type],
          to_stable_id: row[:to_stable_id].presence,
          mapping_id: row[:mapping_id].presence
        }
      )
      saved += 1
    end

    redirect_to new_framework_publication_path(@framework.framework_id), flash: outcome_flash(saved, incomplete)
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
  # parses as an index-keyed hash; a JSON client may post a real array. Accept
  # both as one list of rows.
  #
  # @return [Array<ActionController::Parameters>]
  def mapping_rows
    rows = params.expect(migration_mappings: [ [ :from_stable_id, :mapping_type, :to_stable_id, :mapping_id, :name ] ])
    rows = rows.values if rows.respond_to?(:values)
    Array(rows)
  end

  def survivor_required?(row)
    Operations::Frameworks::DefineMigrationMapping::SURVIVOR_TYPES.include?(row[:mapping_type])
  end

  # A row whose type and survivor match the persisted mapping has nothing to
  # say — re-defining it would only append a no-op event to the stream.
  def unchanged?(row)
    return false if row[:mapping_id].blank?

    existing = persisted_mappings[row[:mapping_id]]
    existing.present? &&
      existing.mapping_type == row[:mapping_type] &&
      existing.to_stable_id == row[:to_stable_id].presence
  end

  def persisted_mappings
    @persisted_mappings ||= FrameworkState::MigrationMapping
      .where(framework_id: @framework.framework_id, published_version: @framework.draft_version)
      .index_by(&:mapping_id)
  end

  def outcome_flash(saved, incomplete)
    notice = saved.zero? ? "No mapping changes to save." : "Saved #{saved} #{'mapping'.pluralize(saved)}."
    return { notice: notice } if incomplete.empty?

    { notice: notice, alert: "Still needs a survivor: #{incomplete.to_sentence}." }
  end
end
