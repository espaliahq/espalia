# frozen_string_literal: true

# Manages collaborator assignments for a single framework.
#
# Mirrors the tenant-wide assignment surface but is scoped to one
# framework and gated by FrameworkPolicy#manage_collaborators?, so a
# framework owner who is not a tenant admin can still curate their
# framework's collaborators.
#
class Frameworks::CollaboratorsController < ApplicationController
  before_action :set_framework

  # GET /frameworks/:framework_id/collaborators/scope_picker
  #
  # Turbo Frame fragment for the scope-entity dropdown when the role
  # changes on the per-framework assignment form. Framework is fixed.
  def scope_picker
    authorize @framework, :manage_collaborators?
    render Views::Tenant::Users::ScopePickerFrame.new(
      framework: @framework, role: params[:role].to_s
    )
  end

  # GET /frameworks/:framework_id/collaborators
  def index
    authorize @framework, :manage_collaborators?
    collaborators = FrameworkState::Collaborator
      .for_framework(@framework.framework_id)
      .order(:role, :person_id)
      .to_a
    rows = FrameworkCollaboratorRow.build_many(collaborators, @framework)
    people = Person.active.order(:name).to_a

    render Views::Frameworks::Collaborators::IndexFrameView.new(
      framework: @framework, rows: rows, people: people
    )
  end

  # POST /frameworks/:framework_id/collaborators
  def create
    authorize @framework, :manage_collaborators?
    p = params.expect(collaborator: [ :person_id, :role, :scope_type, :scope_id ])

    Frameworks::CommandHandler.new.add_collaborator(
      @framework.framework_id, p[:person_id], p[:role],
      scope_type: p[:scope_type].presence,
      scope_id:   p[:scope_id].presence,
      added_by:   current_person&.id
    )
    redirect_to framework_settings_path(@framework.framework_id),
                notice: "Collaborator added."
  rescue RuntimeError => e
    redirect_to framework_settings_path(@framework.framework_id), alert: e.message
  end

  # DELETE /frameworks/:framework_id/collaborators/:id
  # `id` is a composite "person_id:role:scope_type:scope_id".
  def destroy
    authorize @framework, :manage_collaborators?
    person_id, role, scope_type, scope_id = params.expect(:id).split(":", 4)

    Frameworks::CommandHandler.new.remove_collaborator(
      @framework.framework_id, person_id, role,
      scope_type: scope_type.presence,
      scope_id:   scope_id.presence,
      removed_by: current_person&.id
    )
    redirect_to framework_settings_path(@framework.framework_id),
                notice: "Collaborator removed."
  rescue RuntimeError => e
    redirect_to framework_settings_path(@framework.framework_id), alert: e.message
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end
end
