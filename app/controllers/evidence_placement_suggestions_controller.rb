# frozen_string_literal: true

# Decide a placement suggestion from the hub — accept or dismiss — or ask for
# a fresh set. Every answer is a Turbo Stream that replaces the item's
# suggestion block and updates its status line, so the hub never reloads.
# Accept and dismiss dispatch the shared Operations (web + MCP parity);
# "Suggest again" only enqueues the job, and is not an MCP tool: an agent
# reads suggestions and acts on them, it has no reason to spend another
# model call.
class EvidencePlacementSuggestionsController < ApplicationController
  REQUEST_INTERVAL = 1.minute

  before_action :require_person

  # POST /evidence_placement_suggestions/:id/accept
  def accept
    authorize evidence_item, :add_link?, policy_class: EvidencePolicy

    result = Operations::Assessments::AcceptEvidenceSuggestion.call(context: pundit_user, params: { suggestion_id: suggestion.id })
    render_block(message: "Placed on #{cell_label(result)} as #{Views::Evidence::Valence::LABELS[result[:valence]]}.")
  rescue Operations::Base::ParameterError => e
    render_block(message: e.message, error: true)
  end

  # POST /evidence_placement_suggestions/:id/dismiss
  def dismiss
    authorize evidence_item, :add_link?, policy_class: EvidencePolicy

    result = Operations::Assessments::DismissEvidenceSuggestion.call(
      context: pundit_user, params: { suggestion_id: suggestion.id, reason: params[:reason].presence }
    )
    render_block(message: "Dismissed the suggestion to place it on #{cell_label(result)}.")
  rescue Operations::Base::ParameterError => e
    render_block(message: e.message, error: true)
  end

  # POST /evidence_items/:evidence_item_id/placement_suggestions
  def create
    @evidence_item = EvidenceItem.find(params.expect(:evidence_item_id))
    authorize evidence_item, :add_link?, policy_class: EvidencePolicy

    unless Evidence::PlacementSuggestionRows.regenerable?(ActsAsTenant.current_tenant)
      return render_block(message: "Suggestions are switched off for this workspace.", error: true)
    end
    if evidence_item.withdrawn? || evidence_item.source == "self"
      return render_block(message: "Suggestions are made only for feedback someone else gave.", error: true)
    end

    # Each run is a paid model call: one per item a minute, however often
    # the button is pressed.
    if Rails.cache.write("evidence-suggestions:requested:#{evidence_item.id}", true, expires_in: REQUEST_INTERVAL, unless_exist: true)
      Evidence::SuggestPlacementsJob.perform_later(evidence_item.id)
    end
    render_block(message: "Asking for new suggestions. They replace these when you next open the hub.")
  end

  private

  def require_person
    head :forbidden unless current_person
  end

  def suggestion
    @suggestion ||= EvidencePlacementSuggestion.find(params.expect(:id))
  end

  def evidence_item
    @evidence_item ||= EvidenceItem.find(suggestion.evidence_id)
  end

  def cell_label(result)
    role_id = PersonFrameworkAssignment.where(person_id: evidence_item.person_id, framework_id: evidence_item.framework_id)
      .pick(:role_id)
    code = FrameworkState::Level.where(role_id: role_id, ordinal: result[:level_ordinal]).pick(:code)
    [ result[:capability_name], code.presence || "L#{result[:level_ordinal]}" ].compact.join(" · ")
  end

  def render_block(message:, error: false)
    rows = Evidence::PlacementSuggestionRows.for([ evidence_item ])
    block = Views::Evidence::PlacementSuggestions.new(
      item: evidence_item, **rows.fetch(evidence_item.id, Evidence::PlacementSuggestionRows::NONE),
      can_regenerate: Evidence::PlacementSuggestionRows.regenerable?(ActsAsTenant.current_tenant),
      offer_when_empty: EvidenceItem.unplaced.exists?(id: evidence_item.id)
    )
    render turbo_stream: [
      turbo_stream.replace(Views::Evidence::PlacementSuggestions.dom_id_for(evidence_item.id), block),
      turbo_stream.update(Views::Evidence::PlacementSuggestions.status_id_for(evidence_item.id),
                          Views::Evidence::PlacementSuggestionStatus.new(message: message, error: error))
    ], status: error ? :unprocessable_content : :ok
  end
end
