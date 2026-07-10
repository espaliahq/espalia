# frozen_string_literal: true

# Renders the unified evidence modal body into the `#evidence-modal` lazy
# turbo-frame, surface-agnostic (assessment screen + hub). The trigger sets the
# frame `src` to GET /evidence_modal?mode=…; this resolves permissions, prefill,
# and the framework-scoped link options server-side.
#
# Modes:
#   new     — record fresh evidence for a cell (content editable). The cell
#             seeds the "Applies to" block as a fixed row and renders the
#             writing-prompt card up top.
#   edit    — edit an item (content editable iff author; otherwise link-only).
#             ALL active links — the origin cell included — render as uniform,
#             removable "Applies to" rows; there is no top context card. The
#             trigger's cell (when given) is the entry point: its row sorts
#             first and is highlighted.
#   respond — provide evidence for an incoming request (content editable);
#             seeded like :new from the request's cell.
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
      seed_cell: { capability_stable_id: params[:capability_stable_id], level_ordinal: params[:level_ordinal].to_i }
    )
  end

  def render_edit
    item = EvidenceItem.find(params.expect(:evidence_id))
    assignment = assignment_for(item)
    policy = EvidencePolicy.new(pundit_user, item)
    return head :forbidden unless policy.update? || policy.add_link?

    links = ordered_links(item)
    render_modal(
      mode: :edit, assignment: assignment, evidence: item, content_editable: policy.update?,
      linked_coords: links.map { |cap, level, _| [ cap, level ] },
      link_valences: links.to_h { |cap, level, valence| [ [ cap, level ], valence ] }
    )
  end

  def render_respond
    request = EvidenceRequest.find(params.expect(:request_id))
    authorize request, :respond?, policy_class: EvidenceRequestPolicy
    render_modal(
      mode: :respond, assignment: assignment_for(request), request: request, content_editable: true,
      seed_cell: { capability_stable_id: request.capability_stable_id, level_ordinal: request.level_ordinal }
    )
  end

  # @param seed_cell [Hash, nil] the fixed origin cell for :new / :respond
  # @param linked_coords [Array<Array(String, Integer)>] ALL active (cap, level) pairs (:edit)
  # @param link_valences [Hash{Array(String, Integer)=>String,nil}] current valence per active link
  def render_modal(mode:, assignment:, content_editable:, seed_cell: nil, evidence: nil, request: nil,
                   linked_coords: [], link_valences: {})
    options = Evidence::FrameworkCellOptions.new(framework_id: assignment.framework_id, role_id: assignment.role_id)
    expectation_map = options.expectation_map

    linked_cells = linked_coords.map do |capability_stable_id, level_ordinal|
      info = expectation_map["#{capability_stable_id}|#{level_ordinal}"] || {}
      { capability_stable_id: capability_stable_id, level_ordinal: level_ordinal,
        capability_name: info[:capability_name], expectation: info[:expectation],
        illustrations: info[:illustrations] || [],
        valence: link_valences[[ capability_stable_id, level_ordinal ]],
        entry_point: entry_cell == [ capability_stable_id, level_ordinal ] }
    end

    render Views::Evidence::ModalForm.new(
      mode: mode, evidence: evidence, request: request, assignment_id: assignment.id,
      seed_cell: seed_cell, content_editable: content_editable,
      context_block: seed_cell && prompt_context(assignment, seed_cell),
      scope_line: scope_line(assignment),
      link_options: options.link_options, level_options: options.level_options,
      linked_cells: linked_cells, expectation_map: expectation_map, return_to: params[:return_to]
    ), layout: false
  end

  # Whose assessment this is — only needed off the hub (which lists items
  # across people); within an assessment the page header already says so.
  # For :new / :respond the prompt card carries it instead.
  def scope_line(assignment)
    return nil unless params[:return_to] == "hub" && params[:mode] == "edit"

    name = Person.where(id: assignment.person_id).pick(:name)
    role = FrameworkState::Role.where(role_id: assignment.role_id).pick(:name)
    [ ("on #{name}'s assessment" if name), role ].compact.join(" · ").presence
  end

  # The writing-prompt context (capability · level, expectation, examples) for
  # :new / :respond — shown above the content fields while composing.
  def prompt_context(assignment, seed_cell)
    Evidence::CellContextResolver.context(
      framework_id: assignment.framework_id, person_id: assignment.person_id,
      capability_stable_id: seed_cell[:capability_stable_id], level_ordinal: seed_cell[:level_ordinal]
    ).merge(show_role_level: params[:return_to] == "hub")
  end

  def assignment_for(record)
    PersonFrameworkAssignment.find_by!(person_id: record.person_id, framework_id: record.framework_id)
  end

  # ALL active links for an item, as [cap, level, valence] rows — the origin is
  # not special. The entry point (the cell the trigger sits on, when given)
  # sorts first; the rest keep link order.
  def ordered_links(item)
    rows = EvidenceLink.active.where(evidence_id: item.id)
      .order(:linked_at)
      .pluck(:capability_stable_id, :level_ordinal, :valence)
    entry = entry_cell
    rows.partition { |cap, level, _| [ cap, level ] == entry }.flatten(1)
  end

  # The cell the modal was opened from, when the trigger carries one.
  def entry_cell
    return nil if params[:capability_stable_id].blank? || params[:level_ordinal].blank?

    [ params[:capability_stable_id], params[:level_ordinal].to_i ]
  end
end
