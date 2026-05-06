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

    redirect_to assessment_path(@assignment, redirect_params(attrs[:capability_stable_id])),
      status: :see_other, notice: "Evidence recorded."
  rescue RuntimeError => e
    redirect_back fallback_location: assessment_path(@assignment),
      alert: "Could not record evidence: #{e.message}"
  end

  # DELETE /assessments/:assessment_id/evidence/:id
  def destroy
    item = EvidenceItem.find(params.expect(:id))
    authorize item, :withdraw?, policy_class: EvidencePolicy

    PersonDevelopment::CommandHandler.new.withdraw_evidence(
      @assignment.person_id, @assignment.framework_id, item.id,
      withdrawn_by_id: current_person.id,
      reason: params[:reason]
    )

    redirect_to assessment_path(@assignment, redirect_params(item.capability_stable_id)),
      status: :see_other, notice: "Evidence withdrawn."
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue RuntimeError => e
    redirect_back fallback_location: assessment_path(@assignment),
      alert: "Could not withdraw evidence: #{e.message}"
  end

  private

  def require_person
    head :forbidden unless current_person
  end

  def set_assignment
    return unless current_person

    @assignment = PersonFrameworkAssignment.find(params.expect(:assessment_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
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

  def redirect_params(capability_stable_id)
    params = {}
    params[:capability] = capability_stable_id if capability_stable_id.present?
    params
  end

  def user_not_authorized(_exception = nil)
    redirect_back fallback_location: assessment_path(@assignment),
      alert: "You are not authorized to perform this action."
  end
end
