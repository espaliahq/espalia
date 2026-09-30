# frozen_string_literal: true

# What the two exploration controllers share (ADR-22): the assignment, the
# lens the page was read through (`as_role` / `as_level`) to return to, and
# the words for whoever the declaration is shared with.
module Assessments::ExplorationActions
  extend ActiveSupport::Concern

  included do
    before_action :require_person
    before_action :set_assignment
  end

  private

  def lens_assessment_path
    assessment_path(@assignment, { as_role: params[:as_role].presence, as_level: params[:as_level].presence }.compact)
  end

  # "Morgan" to the assessee, "Alex" to the manager side — the person who
  # is told. nil for an assessee with no manager, where nobody is.
  #
  # @return [String, nil]
  def other_party_name
    if @assignment.person_id == current_person.id
      manager_id = RecordedReportingManager.manager_id_for(@assignment.person_id, @assignment.framework_id) ||
        current_person.manager_id
      manager_id && (first_name(Person.where(id: manager_id).pick(:name)) || "your manager")
    else
      first_name(Person.where(id: @assignment.person_id).pick(:name)) || "them"
    end
  end

  def first_name(name)
    name.to_s.split.first.presence
  end

  def require_person
    redirect_to assessments_path, alert: "No person profile linked to your account." unless current_person
  end

  def set_assignment
    return unless current_person

    @assignment = PersonFrameworkAssignment.find(params.expect(:assessment_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to assessments_path, alert: "Assessment not found."
  end
end
