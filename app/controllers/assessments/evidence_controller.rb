# frozen_string_literal: true

# Records, withdraws, and relinks evidence on a person's assessment.
#
# Source ("self" / "manager" / "peer") is inferred from the relationship
# between the current viewer and the assessee — never trusted from the
# request — see {#infer_source}. The viewer must have a Person to record
# evidence; tenant admins without a Person fall through and would land
# as "peer" only if they have a Person.
#
class Assessments::EvidenceController < ApplicationController
  before_action :require_person
  before_action :set_assignment

  # POST /assessments/:assessment_id/evidence
  def create
    authorize @assignment, :create?, policy_class: EvidencePolicy

    attrs = params.expect(evidence: [
      :capability_stable_id, :level_ordinal, :evidence_type, :custom_type_label,
      :title, :content, external_reference: [ :system, :url, :external_id ]
    ])

    level_ordinal = Integer(attrs[:level_ordinal], exception: false)
    unless level_ordinal && FrameworkState::Level.exists?(role_id: @assignment.role_id, ordinal: level_ordinal)
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
      external_reference: attrs[:external_reference]&.to_h
    )

    redirect_to assessment_path(@assignment,
                  redirect_params(attrs[:capability_stable_id], level_ordinal: level_ordinal)),
      status: :see_other, notice: "Evidence recorded."
  rescue PersonDevelopment::Aggregate::CommandError => e
    redirect_back fallback_location: assessment_path(@assignment),
      alert: "Could not record evidence: #{e.message}"
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
      status: :see_other, notice: "Evidence updated."
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue PersonDevelopment::Aggregate::CommandError => e
    fallback = @assignment ? assessment_path(@assignment) : assessments_path
    redirect_back fallback_location: fallback,
      alert: "Could not update evidence: #{e.message}"
  end

  # POST /assessments/:assessment_id/evidence/:id/relink
  def relink
    item = EvidenceItem.find(params.expect(:id))
    authorize item, :relink?, policy_class: EvidencePolicy

    attrs = params.expect(evidence: [ :new_capability_stable_id, :new_level_ordinal, :rationale ])

    new_level = Integer(attrs[:new_level_ordinal], exception: false)
    unless new_level && FrameworkState::Level.exists?(role_id: @assignment.role_id, ordinal: new_level)
      head :unprocessable_content
      return
    end

    PersonDevelopment::CommandHandler.new.relink_evidence(
      @assignment.person_id, @assignment.framework_id, item.id,
      new_capability_stable_id: attrs[:new_capability_stable_id],
      new_level_ordinal: new_level,
      relinked_by_id: current_person.id,
      rationale: attrs[:rationale].to_s.strip.presence
    )

    redirect_to assessment_path(@assignment,
                  redirect_params(attrs[:new_capability_stable_id], level_ordinal: new_level)),
      status: :see_other, notice: "Evidence relinked."
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue PersonDevelopment::Aggregate::CommandError => e
    fallback = @assignment ? assessment_path(@assignment) : assessments_path
    redirect_back fallback_location: fallback,
      alert: "Could not relink evidence: #{e.message}"
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
      status: :see_other, notice: "Evidence withdrawn."
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue PersonDevelopment::Aggregate::CommandError => e
    fallback = @assignment ? assessment_path(@assignment) : assessments_path
    redirect_back fallback_location: fallback,
      alert: "Could not withdraw evidence: #{e.message}"
  end

  private

  def require_person
    return if current_person

    head :forbidden
    throw :abort
  end

  def set_assignment
    @assignment = PersonFrameworkAssignment.find(params.expect(:assessment_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
    throw :abort
  end

  # Determines source from the viewer's relationship to the assessee.
  # Evidence on yourself is "self"; on someone above you in the org chart
  # records "manager" (any chain depth); on anyone else, "peer".
  def infer_source
    assessee = Person.find_by(id: @assignment.person_id)
    return "self"    if assessee&.id == current_person.id
    return "manager" if assessee&.managed_by?(current_person)

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
end
