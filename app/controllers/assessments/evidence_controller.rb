# frozen_string_literal: true

# Records, edits, withdraws, and manages the capability × level links of
# evidence on a person's assessment. One piece of evidence can be linked
# to several capability × level cells (multi-linkage).
#
# Source ("self" / "manager" / "peer") is inferred from the relationship
# between the current viewer and the assessee — never trusted from the
# request — see {#infer_source}. The viewer must have a Person to record
# evidence; tenant admins without a Person fall through and would land
# as "peer" only if they have a Person.
#
class Assessments::EvidenceController < ApplicationController
  include AssessmentVisibility
  include EvidenceDiffSubmit

  before_action :require_person
  before_action :set_assignment

  # POST /assessments/:assessment_id/evidence/save
  #
  # The unified modal's submit. Authorization is per-command: the diff dispatches
  # the existing Operations (RecordEvidence / UpdateEvidence / Add/RemoveEvidenceLink /
  # RespondToEvidenceRequest), each of which authorizes its precise action against
  # the relevant policy — a single controller-level check can't capture all modes.
  def save
    # Baseline gate: the caller must be able to record evidence on this
    # assessment. The diff then authorizes each command precisely (update? for a
    # content change, add_link?/remove_link? for linkage), so a tampered form
    # can't escalate beyond what each operation permits.
    authorize @assignment, :create?, policy_class: EvidencePolicy
    touched = apply_evidence_diff
    render turbo_stream: touched.cells.uniq.map { |cap, level| cell_evidence_stream(cap, level) }
  rescue Operations::Base::ParameterError, PersonDevelopment::Aggregate::CommandError => e
    redirect_back fallback_location: assessment_path(@assignment), alert: e.message, status: :see_other
  end

  # POST /assessments/:assessment_id/evidence
  def create
    authorize @assignment, :create?, policy_class: EvidencePolicy

    attrs = params.expect(evidence: [
      :capability_stable_id, :level_ordinal, :evidence_type, :custom_type_label,
      :title, :content, external_reference: [ :system, :url, :external_id ],
      additional_links: []
    ])

    level_ordinal = Integer(attrs[:level_ordinal], exception: false)
    unless level_ordinal && valid_evidence_cell?(attrs[:capability_stable_id], level_ordinal)
      head :unprocessable_content
      return
    end

    additional_links = parse_additional_links(attrs[:additional_links])
    if additional_links == :invalid
      head :unprocessable_content
      return
    end

    # Validate the external reference upfront so a malicious URL can't
    # land in the event stream. ExternalReference rejects non-http(s)
    # schemes (XSS via `javascript:` etc); doing it here keeps bad data
    # out of the projection rather than letting it fail on replay.
    ext_attrs = attrs[:external_reference]&.to_h
    if ext_attrs.present?
      candidate = ExternalReference.new(ext_attrs)
      unless candidate.valid?
        head :unprocessable_content
        return
      end
    end

    evidence_id = SecureRandom.uuid_v7
    PersonDevelopment::CommandHandler.new.record_evidence(
      @assignment.person_id, @assignment.framework_id, evidence_id,
      capability_stable_id: attrs[:capability_stable_id],
      level_ordinal: level_ordinal,
      source: infer_source,
      evidence_type: attrs[:evidence_type],
      custom_type_label: attrs[:custom_type_label].presence,
      title: attrs[:title].presence,
      content: attrs[:content].to_s,
      author_id: current_person.id,
      external_reference: attrs[:external_reference]&.to_h,
      additional_links: additional_links
    )

    # Respond with turbo_stream so Turbo applies the update in place
    # rather than navigating to the redirect — full-page navigation
    # resets the scroll position to the top, throwing the user away
    # from the cell they were working in.
    respond_to do |format|
      format.turbo_stream { render_evidence_list_stream(attrs[:capability_stable_id], level_ordinal) }
      format.html do
        redirect_to assessment_path(@assignment,
                      redirect_params(attrs[:capability_stable_id], level_ordinal: level_ordinal)),
          status: :see_other, notice: "Feedback recorded."
      end
    end
  rescue PersonDevelopment::Aggregate::CommandError => e
    redirect_back fallback_location: assessment_path(@assignment),
      alert: "Could not record feedback: #{e.message}"
  end

  # PATCH /assessments/:assessment_id/evidence/:id
  def update
    item = EvidenceItem.find(params.expect(:id))
    authorize item, :update?, policy_class: EvidencePolicy

    attrs = params.expect(evidence: [
      :evidence_type, :custom_type_label, :title, :content,
      external_reference: [ :system, :url, :external_id ]
    ])

    ext_attrs = attrs[:external_reference]&.to_h
    if ext_attrs.present?
      candidate = ExternalReference.new(ext_attrs)
      unless candidate.valid?
        head :unprocessable_content
        return
      end
    end

    PersonDevelopment::CommandHandler.new.update_evidence(
      @assignment.person_id, @assignment.framework_id, item.id,
      title: attrs[:title].presence,
      content: attrs[:content].to_s,
      evidence_type: attrs[:evidence_type],
      custom_type_label: attrs[:custom_type_label].presence,
      external_reference: ext_attrs,
      edited_by_id: current_person.id
    )

    redirect_to assessment_path(@assignment,
                  redirect_params(item.capability_stable_id, level_ordinal: item.level_ordinal)),
      status: :see_other, notice: "Feedback updated."
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue PersonDevelopment::Aggregate::CommandError => e
    fallback = @assignment ? assessment_path(@assignment) : assessments_path
    redirect_back fallback_location: fallback,
      alert: "Could not update feedback: #{e.message}"
  end

  # POST /assessments/:assessment_id/evidence/:id/add_link
  #
  # Links the evidence to an additional (capability, level). Re-renders the
  # ORIGINATING cell's evidence list (the cell the user acted from) via
  # turbo_stream so the "also linked to N" indicator updates in place.
  def add_link
    item = EvidenceItem.find(params.expect(:id))
    authorize item, :add_link?, policy_class: EvidencePolicy

    attrs = params.expect(evidence: [ :capability_stable_id, :level_ordinal,
                                      :from_capability_stable_id, :from_level_ordinal, :rationale ])

    target_level = Integer(attrs[:level_ordinal], exception: false)
    unless target_level && valid_evidence_cell?(attrs[:capability_stable_id], target_level)
      head :unprocessable_content
      return
    end

    PersonDevelopment::CommandHandler.new.add_evidence_link(
      @assignment.person_id, @assignment.framework_id, item.id,
      capability_stable_id: attrs[:capability_stable_id],
      level_ordinal: target_level,
      linked_by_id: current_person.id,
      rationale: attrs[:rationale].to_s.strip.presence
    )

    from_cap = attrs[:from_capability_stable_id].presence || item.capability_stable_id
    from_level = Integer(attrs[:from_level_ordinal], exception: false) || item.level_ordinal
    respond_to do |format|
      format.turbo_stream do
        render_item_cells_stream(item.id, extra_cells: [ [ from_cap, from_level ] ])
      end
      format.html do
        redirect_to assessment_path(@assignment, redirect_params(from_cap, level_ordinal: from_level)),
          status: :see_other, notice: "Feedback linked."
      end
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue PersonDevelopment::Aggregate::CommandError => e
    fallback = @assignment ? assessment_path(@assignment) : assessments_path
    redirect_back fallback_location: fallback,
      alert: "Could not link feedback: #{e.message}"
  end

  # POST /assessments/:assessment_id/evidence/:id/remove_link
  #
  # Removes one (capability, level) link; the item keeps its other links.
  # Re-renders the cell the link was removed from so the item disappears
  # from it in place.
  def remove_link
    item = EvidenceItem.find(params.expect(:id))
    authorize item, :remove_link?, policy_class: EvidencePolicy

    attrs = params.expect(evidence: [ :capability_stable_id, :level_ordinal, :reason ])

    level = Integer(attrs[:level_ordinal], exception: false)
    unless level
      head :unprocessable_content
      return
    end

    PersonDevelopment::CommandHandler.new.remove_evidence_link(
      @assignment.person_id, @assignment.framework_id, item.id,
      capability_stable_id: attrs[:capability_stable_id],
      level_ordinal: level,
      removed_by_id: current_person.id,
      reason: attrs[:reason].to_s.strip.presence
    )

    respond_to do |format|
      format.turbo_stream do
        # The removed cell is no longer an active link, so include it
        # explicitly; the item's remaining cells re-render to refresh their
        # "also linked to N" counts.
        render_item_cells_stream(item.id, extra_cells: [ [ attrs[:capability_stable_id], level ] ])
      end
      format.html do
        redirect_to assessment_path(@assignment,
                      redirect_params(attrs[:capability_stable_id], level_ordinal: level)),
          status: :see_other, notice: "Feedback link removed."
      end
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue PersonDevelopment::Aggregate::CommandError => e
    fallback = @assignment ? assessment_path(@assignment) : assessments_path
    redirect_back fallback_location: fallback,
      alert: "Could not remove feedback link: #{e.message}"
  end

  # DELETE /assessments/:assessment_id/evidence/:id
  def destroy
    item = EvidenceItem.find(params.expect(:id))
    authorize item, :withdraw?, policy_class: EvidencePolicy

    reason = params.fetch(:evidence, {}).permit(:reason)[:reason]
    PersonDevelopment::CommandHandler.new.withdraw_evidence(
      @assignment.person_id, @assignment.framework_id, item.id,
      withdrawn_by_id: current_person.id,
      reason: reason
    )

    redirect_to assessment_path(@assignment,
                  redirect_params(item.capability_stable_id, level_ordinal: item.level_ordinal)),
      status: :see_other, notice: "Feedback withdrawn."
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue PersonDevelopment::Aggregate::CommandError => e
    fallback = @assignment ? assessment_path(@assignment) : assessments_path
    redirect_back fallback_location: fallback,
      alert: "Could not withdraw feedback: #{e.message}"
  end

  private

  def require_person
    return if current_person

    # Rendering halts the before_action chain (Rails checks `performed?`), so
    # set_assignment won't run. Do NOT `throw :abort` — the around_action
    # `wrap_with_audit_metadata` (ApplicationController) wraps these callbacks,
    # and the throw escapes its `yield` uncaught, turning a 403 into a 500.
    head :forbidden
  end

  def set_assignment
    @assignment = PersonFrameworkAssignment.find(params.expect(:assessment_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # Determines source from the viewer's relationship to the assessee.
  # Evidence on yourself is "self"; on someone above you in the org chart
  # records "manager" (any chain depth); on anyone else, "peer".
  def infer_source
    assessee = assessment_assessee
    return "self"    if assessee&.id == current_person.id
    return "manager" if assessee&.managed_by?(current_person)
    # An active rating delegate acts in the reporting manager's place.
    return "manager" if active_rating_delegate?

    "peer"
  end

  # Builds the query params for the post-action redirect back to the
  # assessment page. Includes the focused capability AND its category so
  # the matrix lands on the right tab and pre-expands the right row;
  # without the category, `resolve_active_category_id` falls back to the
  # first category and the user sees a tab where their just-recorded
  # evidence isn't visible. When `level_ordinal` is supplied, the cell
  # is also focused — important for edit/withdraw flows where the user
  # triggered the action from a focused cell and expects to return to
  # the same focused state (the evidence list only renders in the
  # focused cell, per assessments.md).
  def redirect_params(capability_stable_id, level_ordinal: nil)
    opts = {}
    return opts unless capability_stable_id.present?

    opts[:capability] = capability_stable_id
    if (category_id = category_id_for(capability_stable_id))
      opts[:category] = category_id
    end
    opts[:level_ordinal] = level_ordinal if level_ordinal
    opts
  end

  # Looks up the category for a capability stable_id, scoped to the
  # assignment's framework so cross-version stable_id collisions resolve
  # to the right category.
  def category_id_for(capability_stable_id)
    FrameworkState::Capability
      .joins(:category)
      .where(stable_id: capability_stable_id)
      .merge(FrameworkState::CapabilityCategory.where(framework_id: @assignment.framework_id))
      .pick(:category_id)
  end

  def user_not_authorized(_exception = nil)
    fallback = @assignment ? assessment_path(@assignment) : assessments_path
    redirect_back fallback_location: fallback,
      alert: "You are not authorized to perform this action."
  end

  # Renders the evidence list for the (capability, level) cell where the
  # new item just landed. Used by the format.turbo_stream branch of
  # `create` so the modal-driven submit updates the list in-place
  # without a full-page redirect.
  def render_evidence_list_stream(capability_stable_id, level_ordinal)
    render turbo_stream: cell_evidence_stream(capability_stable_id, level_ordinal)
  end

  # Re-renders EVERY cell an item touches after a link change, so a link
  # added to / removed from another (visible) cell updates live and the
  # "also linked to N other places" counts stay correct on all visible
  # cells the item still appears in. `extra_cells` covers the cell the user
  # acted from / the cell a link was just removed from (no longer an active
  # link, so not in the active set). Turbo ignores stream targets not
  # currently in the DOM, so off-screen cells are safely skipped.
  #
  # The acting user's own projection broadcast is suppressed (see
  # assessment_sync_controller), so this response is what updates their view.
  def render_item_cells_stream(evidence_id, extra_cells: [])
    cells = EvidenceLink.active.where(evidence_id: evidence_id)
      .pluck(:capability_stable_id, :level_ordinal)
    streams = (cells + extra_cells).uniq.map do |cap, level|
      cell_evidence_stream(cap, level)
    end
    render turbo_stream: streams
  end

  def cell_evidence_stream(capability_stable_id, level_ordinal)
    turbo_stream.replace(
      "evidence-list-#{capability_stable_id}-#{level_ordinal}",
      render_to_string(
        Views::Assessments::Evidence::List.new(
          items: evidence_items_for(capability_stable_id, level_ordinal),
          assessment_id: @assignment.id,
          viewer_person_id: current_person.id,
          can_create: true,
          can_relink_others: viewer_can_relink_others_evidence?,
          capability_stable_id: capability_stable_id,
          level_ordinal: level_ordinal
        ),
        layout: false
      )
    )
  end

  # Items linked to one (capability, level) cell, ordered by recording
  # time, each carrying its total active-link count so the card can render
  # the "also linked to N other places" indicator and gate "remove from
  # this cell". Driven off {EvidenceLink} (an item appears in a cell when
  # it has an active link there), not the item's origin columns.
  def evidence_items_for(capability_stable_id, level_ordinal)
    links = EvidenceLink.active
      .for_person(@assignment.person_id)
      .for_framework(@assignment.framework_id)
      .for_cell(capability_stable_id, level_ordinal)
    item_ids = links.pluck(:evidence_id)
    return [] if item_ids.empty?

    scope = EvidenceItem.active.where(id: item_ids).includes(:author)
    scope = scope.where(author_id: current_person.id) unless viewer_sees_all_evidence?
    items = scope.order(:recorded_at).to_a
    counts = EvidenceLink.active.where(evidence_id: items.map(&:id)).group(:evidence_id).count
    items.each { |item| item.active_link_count = counts[item.id] }
    items
  end

  # Parses the optional `additional_links[]` array of "capStableId|level"
  # tokens from the create form into the
  # { capability_stable_id:, level_ordinal: } shape the command handler
  # expects. Returns `:invalid` if any token is malformed or does not name a
  # real cell in this assessment's matrix.
  #
  # `viewer_can_relink_others_evidence?` (used when re-rendering the evidence
  # list) and the visibility helpers come from {AssessmentVisibility}.
  def parse_additional_links(raw)
    return [] if raw.blank?

    Array(raw).reject(&:blank?).map do |token|
      cap, level = token.to_s.split("|", 2)
      level = Integer(level, exception: false)
      return :invalid unless valid_evidence_cell?(cap, level)

      { capability_stable_id: cap, level_ordinal: level }
    end
  end

  # Whether (capability_stable_id, level_ordinal) is a real cell in THIS
  # assessment's matrix: the capability belongs to the assignment's framework
  # (`category_id_for` is framework-scoped, so a foreign / non-existent
  # capability resolves to nil) AND the level exists for the role. Guards the
  # write paths against crafted requests that would otherwise persist a link
  # to a cell the matrix can't render or clean up. The remove path is left
  # permissive so links onto archived/migrated capabilities can still be
  # detached.
  def valid_evidence_cell?(capability_stable_id, level_ordinal)
    return false if capability_stable_id.blank? || level_ordinal.nil?

    category_id_for(capability_stable_id).present? &&
      FrameworkState::Level.exists?(role_id: @assignment.role_id, ordinal: level_ordinal)
  end
end
