# frozen_string_literal: true

# A category's ratings carried from the last cycle, listed with what changed
# since, and confirmed in one go (#480). Confirming is the viewer's own side
# only — their self ratings, or the manager ratings they give — and runs
# {Operations::Assessments::ConfirmCarriedRatings}, the same code as the MCP
# tool. Reads and writes the home role; a lens has its own pills.
class Assessments::CarriedRatingsController < ApplicationController
  include AssessmentVisibility

  NOTHING_TO_CONFIRM = "There are no carried ratings for you to confirm here."

  before_action :require_person
  before_action :set_assignment

  # GET /assessments/:assessment_id/carried_ratings?category_id=…
  def index
    # Viewing first: once alignment starts there is no side to confirm, and a
    # stale link should say so rather than read as a permission failure.
    authorize @assignment, :show?
    return redirect_to(assessment_path(@assignment), alert: NOTHING_TO_CONFIRM) unless perspective

    authorize @assignment, rating_predicate

    matrix = Assessments::MatrixDataBuilder.for_lens(
      lens: home_lens, context: viewer_context,
      viewer_person_id: current_person.id, viewer_sees_all_evidence: viewer_sees_all_evidence?
    )
    category = matrix[:categories].find { |c| c[:category].category_id == params[:category_id] }
    return redirect_to(assessment_path(@assignment), alert: NOTHING_TO_CONFIRM) unless category

    render Views::Assessments::CarriedRatings::IndexView.new(
      assignment: @assignment, category: category, context: viewer_context,
      merged_levels: matrix[:merged_levels], person_level: matrix[:person_level],
      cycle_id: @assignment.current_open_cycle&.cycle_id, assessee_name: assessee_name,
      user: current_user, current_tenant: ActsAsTenant.current_tenant, tenants: current_user_tenants
    )
  end

  # POST /assessments/:assessment_id/carried_ratings
  def create
    authorize @assignment, :show?
    back = assessment_path(@assignment, category: params[:category_id].presence)
    return redirect_to(back, alert: NOTHING_TO_CONFIRM) unless perspective

    authorize @assignment, rating_predicate

    cells = Array(params[:cells]).filter_map do |token|
      stable_id, raw_ordinal = token.to_s.split("|", 2)
      ordinal = Integer(raw_ordinal.to_s, 10, exception: false)
      { capability_stable_id: stable_id, level_ordinal: ordinal } if stable_id.present? && ordinal
    end
    return redirect_to(carried_back, alert: "Tick at least one rating to confirm.") if cells.empty?

    result = Operations::Assessments::ConfirmCarriedRatings.call(
      context: pundit_user, params: { assignment_id: @assignment.id, perspective: perspective, cells: cells }
    )
    redirect_to back, notice: confirmation_notice(result)
  rescue Operations::Base::ParameterError => e
    redirect_to back, alert: e.message
  end

  private

  # "self" or "manager"; nil once alignment has started, when individual
  # ratings are frozen and there is nothing to confirm.
  def perspective
    { self: "self", manager: "manager" }[viewer_context]
  end

  def rating_predicate
    viewer_context == :manager ? :create_manager_rating? : :create_self_rating?
  end

  def viewer_context
    @viewer_context ||= Assessments::ViewerContext.for(assignment: @assignment, authorization: pundit_user)
  end

  def home_lens
    Assessments::Lens.resolve(assignment: @assignment, as_role: nil, as_level: nil)
  end

  def assessee_name
    @assignment.person_id == current_person.id ? nil : Person.where(id: @assignment.person_id).pick(:name)
  end

  def carried_back
    assessment_carried_ratings_path(@assignment, category_id: params[:category_id])
  end

  def confirmation_notice(result)
    confirmed = result[:confirmed].size
    notice = "Confirmed #{confirmed} carried #{'rating'.pluralize(confirmed)} for this cycle."
    skipped = result[:skipped].size
    skipped.zero? ? notice : "#{notice} #{skipped} could not be confirmed and #{skipped == 1 ? 'is' : 'are'} unchanged."
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end

  def require_person
    redirect_to assessments_path, alert: "No person profile linked to your account." unless current_person
  end

  def set_assignment
    @assignment = PersonFrameworkAssignment.find(params.expect(:assessment_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to assessments_path, alert: "Assessment not found."
  end
end
