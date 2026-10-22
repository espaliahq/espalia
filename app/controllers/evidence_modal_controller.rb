# frozen_string_literal: true

# Renders the unified evidence modal body into the `#evidence-modal` lazy
# turbo-frame, surface-agnostic (assessment screen + hub). The trigger sets the
# frame `src` to GET /evidence_modal?mode=…; this resolves permissions, prefill,
# and the framework-scoped link options server-side.
#
# Modes:
#   give    — the first step of volunteering feedback: who is it for? A search
#             over the recipient directory; picking a row navigates the frame
#             to :new for that person's assignment.
#   new     — record fresh evidence (content editable). With a cell, it seeds
#             the "Applies to" block as a fixed row and renders the
#             writing-prompt card up top; without one, the block starts
#             empty and the item may be saved unplaced.
#   edit    — edit an item (content editable iff author; otherwise link-only).
#             ALL active links — the origin cell included — render as uniform,
#             removable "Applies to" rows; there is no top context card. The
#             trigger's cell (when given) is the entry point: its row sorts
#             first and is highlighted. With `suggestions=pending` (the hub's
#             "Adjust"), the item's pending placement suggestions follow as
#             staged rows, valence preselected.
#   respond — provide evidence for an incoming request (content editable);
#             seeded like :new from the request's cell.
class EvidenceModalController < ApplicationController
  before_action :require_person

  # GET /evidence_modal
  def show
    case params[:mode]
    when "give"    then render_give
    when "new"     then render_new
    when "edit"    then render_edit
    when "respond" then render_respond
    else head :bad_request
    end
  end

  # GET /evidence_modal/recipients?q= — the give step's typeahead frame.
  def recipients
    authorize PersonFrameworkAssignment, :index?
    entries = recipient_directory.call(params[:q], limit: Assessments::FeedbackRecipients::DEFAULT_LIMIT)
    render Views::Evidence::RecipientCandidatesFrame.new(entries: entries, query: params[:q], return_to: params[:return_to],
                                                         draft_token: params[:draft_token]),
           layout: false
  end

  private

  def require_person
    head :forbidden unless current_person
  end

  def render_give
    authorize PersonFrameworkAssignment, :index?
    render Views::Evidence::RecipientPickerForm.new(
      suggestions: recipient_directory.suggestions,
      candidates_url: recipients_evidence_modal_path(return_to: params[:return_to], draft_token: params[:draft_token]),
      return_to: params[:return_to], draft_token: params[:draft_token]
    ), layout: false
  end

  def recipient_directory
    Assessments::FeedbackRecipients.new(giver: current_person)
  end

  # A cell seeds the form when the trigger names one (the assessment page);
  # the give step names none, and the item may then be saved unplaced.
  def render_new
    assignment = PersonFrameworkAssignment.find(params.expect(:assignment_id))
    authorize assignment, :create?, policy_class: EvidencePolicy
    seed_cell = if params[:capability_stable_id].present?
      { capability_stable_id: params[:capability_stable_id], level_ordinal: params[:level_ordinal].to_i }
    end
    render_modal(mode: :new, assignment: assignment, content_editable: true, seed_cell: seed_cell,
                 recipient: (Person.find_by(id: assignment.person_id) if seed_cell.nil?),
                 draft: draft)
  end

  # A Slack draft the signed-in author is finishing: only theirs, only while open.
  def draft
    return nil if params[:draft_token].blank?

    FeedbackDraft.open_for(token: params[:draft_token], email: current_user.email)
  end

  def render_edit
    item = EvidenceItem.find(params.expect(:evidence_id))
    assignment = assignment_for(item)
    policy = EvidencePolicy.new(pundit_user, item)
    return head :forbidden unless policy.update? || policy.add_link?

    links = ordered_links(item)
    render_modal(
      mode: :edit, assignment: assignment, evidence: item, content_editable: policy.update?,
      recipient: (Person.find_by(id: assignment.person_id) if links.empty?),
      linked_coords: links.map { |cap, level, _| [ cap, level ] },
      link_valences: links.to_h { |cap, level, valence| [ [ cap, level ], valence ] },
      staged_suggestions: staged_suggestions(item, links)
    )
  end

  # Pending suggestions to stage beside the item's links, for "Adjust". A
  # suggestion on a cell already linked has nothing to stage.
  def staged_suggestions(item, links)
    return [] unless params[:suggestions] == "pending"

    linked = links.map { |cap, level, _| [ cap, level ] }
    EvidencePlacementSuggestion.pending.for_evidence(item.id).most_confident_first.reject { |s| linked.include?(s.cell) }
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
  # @param staged_suggestions [Array<EvidencePlacementSuggestion>] staged as new rows (:edit, "Adjust")
  def render_modal(mode:, assignment:, content_editable:, seed_cell: nil, evidence: nil, request: nil,
                   linked_coords: [], link_valences: {}, recipient: nil, draft: nil, staged_suggestions: [])
    options = Evidence::FrameworkCellOptions.new(framework_id: assignment.framework_id, role_id: assignment.role_id)
    expectation_map = options.expectation_map

    comment_counts = link_comment_counts(evidence, linked_coords)
    linked_cells = linked_coords.map do |capability_stable_id, level_ordinal|
      info = expectation_map["#{capability_stable_id}|#{level_ordinal}"] || {}
      { capability_stable_id: capability_stable_id, level_ordinal: level_ordinal,
        capability_name: info[:capability_name], expectation: info[:expectation],
        illustrations: info[:illustrations] || [],
        valence: link_valences[[ capability_stable_id, level_ordinal ]],
        comment_count: comment_counts[[ capability_stable_id, level_ordinal ]].to_i,
        entry_point: entry_cell == [ capability_stable_id, level_ordinal ] }
    end
    linked_cells += suggestion_rows(staged_suggestions, expectation_map)

    render Views::Evidence::ModalForm.new(
      mode: mode, evidence: evidence, request: request, assignment_id: assignment.id,
      seed_cell: seed_cell, content_editable: content_editable,
      context_block: seed_cell && prompt_context(assignment, seed_cell),
      scope_line: scope_line(assignment),
      link_options: options.link_options, level_options: options.level_options,
      linked_cells: linked_cells, expectation_map: expectation_map, return_to: params[:return_to],
      recipient: recipient_block(assignment, recipient), draft: draft
    ), layout: false
  end

  # A staged suggestion is a new row like one picked by hand, carrying the
  # suggestion's id so the save can attribute or dismiss it. One the role no
  # longer reads is left out: there is no row to show for it.
  def suggestion_rows(suggestions, expectation_map)
    suggestions.filter_map do |suggestion|
      info = expectation_map["#{suggestion.capability_stable_id}|#{suggestion.level_ordinal}"]
      next unless info

      { capability_stable_id: suggestion.capability_stable_id, level_ordinal: suggestion.level_ordinal,
        capability_name: info[:capability_name], expectation: info[:expectation],
        illustrations: info[:illustrations] || [], valence: suggestion.valence,
        suggestion_id: suggestion.id, rationale: suggestion.rationale }
    end
  end

  # Whose assessment the feedback lands on, for the forms that have no cell
  # card to say so: the give step's :new, and an :edit of an unplaced item.
  # Nil when the viewer IS the assessee — writing on your own assessment needs
  # no introduction and no visibility warning.
  def recipient_block(assignment, recipient)
    return nil if recipient.nil? || recipient.id == current_person.id

    role = FrameworkState::Role.where(role_id: assignment.role_id).pick(:name)
    level = FrameworkState::Level.where(level_id: assignment.level_id).pick(:code)
    { name: recipient.name, scope: [ role, level ].compact.join(" · ").presence }
  end

  # Active discussion-comment counts per linked cell (:edit only) — the
  # "Applies to" row discloses an existing thread before the user stages
  # the link's removal.
  #
  # @return [Hash{Array(String, Integer) => Integer}]
  def link_comment_counts(evidence, linked_coords)
    return {} if evidence.nil? || linked_coords.empty?

    PersonDevelopmentComment.evidence_link_counts(evidence.id)
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
