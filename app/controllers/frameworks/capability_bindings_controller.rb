# frozen_string_literal: true

# Manages a capability's role bindings from the explorer's edit-mode row-actions
# kebab ("Edit roles…"). The modal body is the `binding-editor` Turbo Frame; each
# add / update / remove re-renders that frame in place so the modal stays open
# for list management.
#
# Add / remove are shape-changing (auto-open a draft, deferred to publish);
# weight edits are shape-preserving (apply live). All three dispatch the shared
# Operations::Frameworks::*CapabilityRoleBinding classes so web and MCP behave
# identically. Restricted to edit-rights holders (FrameworkPolicy#update_binding?
# / #add_binding? / #remove_binding?).
class Frameworks::CapabilityBindingsController < ApplicationController
  before_action :set_framework

  # GET /frameworks/:framework_id/capability_bindings?capability_id=
  def index
    authorize @framework, :update_binding?
    @capability = find_capability(params[:capability_id])
    return head :not_found unless @capability

    render_editor
  end

  # POST /frameworks/:framework_id/capability_bindings
  def create
    authorize @framework, :add_binding?
    attrs = bind_params
    @capability_id = attrs[:capability_id]

    Operations::Frameworks::AddCapabilityRoleBinding.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id, capability_id: attrs[:capability_id],
        role_id: attrs[:role_id], weight: numeric(attrs[:weight])
      }.compact
    )
    render_editor(@capability_id)
  rescue Operations::Base::ParameterError, RuntimeError => e
    render_editor(@capability_id, error: e.message)
  end

  # PATCH /frameworks/:framework_id/capability_bindings/:id  (id = binding_id)
  def update
    authorize @framework, :update_binding?
    cap_id = capability_id_for_binding(params[:id])

    Operations::Frameworks::UpdateCapabilityRoleBinding.call(
      context: pundit_user,
      params: { framework_id: @framework.framework_id, binding_id: params[:id],
                weight: numeric(params.dig(:binding, :weight)) }.compact
    )
    render_editor(cap_id)
  rescue Operations::Base::ParameterError, RuntimeError => e
    render_editor(cap_id, error: e.message)
  end

  # DELETE /frameworks/:framework_id/capability_bindings/:id  (id = binding_id)
  def destroy
    authorize @framework, :remove_binding?
    cap_id = capability_id_for_binding(params[:id])

    Operations::Frameworks::RemoveCapabilityRoleBinding.call(
      context: pundit_user,
      params: { framework_id: @framework.framework_id, binding_id: params[:id] }
    )
    render_editor(cap_id)
  rescue Operations::Base::ParameterError, RuntimeError => e
    render_editor(cap_id, error: e.message)
  end

  private

  def bind_params
    params.expect(binding: [ :capability_id, :role_id, :weight ])
  end

  # Coerce a form-submitted weight string to a number; nil/blank → nil (let the
  # Operation apply its default / leave-unchanged semantics).
  def numeric(value)
    value.present? ? value.to_f : nil
  end

  # Re-render the binding-editor frame for `capability_id` (defaults to the
  # already-loaded @capability). Always reloads a fresh graph so add / remove /
  # weight edits show immediately. A missing capability (e.g. removed) renders an
  # empty editor rather than crashing.
  def render_editor(capability_id = nil, error: nil)
    @capability ||= find_capability(capability_id) if capability_id
    return head :unprocessable_content unless @capability

    render Views::Frameworks::Explorer::BindingEditorFrame.new(
      framework_id: @framework.framework_id,
      capability: @capability,
      roles_by_id: roles_by_id,
      error: error
    ), layout: false
  end

  # Resolve the capability from the explorer graph (incl. draft-added), scoped to
  # this framework. A fresh load each call so post-op state is current.
  def find_capability(capability_id)
    return nil if capability_id.blank?

    fresh_graph.capability_categories.flat_map(&:capabilities)
      .find { |c| c.capability_id == capability_id }
  end

  # Capability owning a binding (for re-rendering the right editor after
  # update/remove, which carry only the binding_id).
  def capability_id_for_binding(binding_id)
    fresh_graph.capability_categories.flat_map(&:capabilities)
      .find { |c| c.bindings.any? { |b| b.binding_id == binding_id } }
      &.capability_id
  end

  def fresh_graph
    Frameworks::ExplorerGraph.load(@framework.framework_id) ||
      Frameworks::ExplorerGraph.rebuild(@framework.framework_id)
  end

  # { role_id => FrameworkState::Role } for every role in this framework — used to
  # label bound roles and offer the unbound ones. Roles aren't draft-editable, so
  # the published read model is authoritative.
  def roles_by_id
    family_ids = FrameworkState::RoleFamily.where(framework_id: @framework.framework_id).pluck(:role_family_id)
    FrameworkState::Role.where(role_family_id: family_ids).index_by(&:role_id)
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end
end
