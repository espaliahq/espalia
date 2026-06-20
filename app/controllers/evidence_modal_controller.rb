# frozen_string_literal: true

# Renders the unified evidence modal body into the `#evidence-modal` lazy
# turbo-frame, surface-agnostic (assessment screen + hub). The trigger sets the
# frame `src` to GET /evidence_modal?mode=…; this resolves permissions, prefill,
# the primary-cell context, and the framework-scoped link options server-side.
#
# Modes:
#   new     — record fresh evidence for a cell (content editable)
#   edit    — edit an item (content editable iff author; otherwise link-only)
#   respond — provide evidence for an incoming request (content editable)
class EvidenceModalController < ApplicationController
  before_action :require_person

  # GET /evidence_modal
  def show
    case params[:mode]
    when "new"     then render_new
    when "edit"    then render_edit
    when "respond" then render_respond
    else head :bad_request
    end
  end

  private

  def require_person
    head :forbidden unless current_person
  end

  def render_new
    assignment = PersonFrameworkAssignment.find(params.expect(:assignment_id))
    authorize assignment, :create?, policy_class: EvidencePolicy
    render_modal(
      mode: :new, assignment: assignment, content_editable: true,
      primary_cell: { capability_stable_id: params[:capability_stable_id], level_ordinal: params[:level_ordinal].to_i }
    )
  end

  def render_edit
    item = EvidenceItem.find(params.expect(:evidence_id))
    assignment = assignment_for(item)
    policy = EvidencePolicy.new(pundit_user, item)
    return head :forbidden unless policy.update? || policy.add_link?

    render_modal(
      mode: :edit, assignment: assignment, evidence: item, content_editable: policy.update?,
      primary_cell: { capability_stable_id: item.capability_stable_id, level_ordinal: item.level_ordinal },
      linked_coords: extra_link_coords(item)
    )
  end

  def render_respond
    request = EvidenceRequest.find(params.expect(:request_id))
    authorize request, :respond?, policy_class: EvidenceRequestPolicy
    render_modal(
      mode: :respond, assignment: assignment_for(request), request: request, content_editable: true,
      primary_cell: { capability_stable_id: request.capability_stable_id, level_ordinal: request.level_ordinal }
    )
  end

  # @param linked_coords [Array<Array(String, Integer)>] extra (cap, level) pairs
  def render_modal(mode:, assignment:, primary_cell:, content_editable:, evidence: nil, request: nil, linked_coords: [])
    options = Evidence::FrameworkCellOptions.new(framework_id: assignment.framework_id, role_id: assignment.role_id)
    expectation_map = options.expectation_map
    context = Evidence::CellContextResolver.context(
      framework_id: assignment.framework_id, person_id: assignment.person_id,
      capability_stable_id: primary_cell[:capability_stable_id], level_ordinal: primary_cell[:level_ordinal]
    ).merge(show_role_level: params[:return_to] == "hub")

    linked_cells = linked_coords.map do |capability_stable_id, level_ordinal|
      info = expectation_map["#{capability_stable_id}|#{level_ordinal}"] || {}
      { capability_stable_id: capability_stable_id, level_ordinal: level_ordinal,
        capability_name: info[:capability_name], expectation: info[:expectation] }
    end

    render Views::Evidence::ModalForm.new(
      mode: mode, evidence: evidence, request: request, assignment_id: assignment.id,
      primary_cell: primary_cell, content_editable: content_editable, context_block: context,
      link_options: options.link_options, level_options: options.level_options,
      linked_cells: linked_cells, expectation_map: expectation_map, return_to: params[:return_to]
    ), layout: false
  end

  def assignment_for(record)
    PersonFrameworkAssignment.find_by!(person_id: record.person_id, framework_id: record.framework_id)
  end

  # Active link cells for an item, excluding its origin cell (the primary).
  def extra_link_coords(item)
    EvidenceLink.active.where(evidence_id: item.id).pluck(:capability_stable_id, :level_ordinal)
      .reject { |cap, level| cap == item.capability_stable_id && level == item.level_ordinal }
  end
end
