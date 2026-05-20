# frozen_string_literal: true

class PagesController < ApplicationController
  # GET /
  def index
    authorize :pages, :index?
    # Preserve any incoming flash (e.g. Pundit's redirect_back fallback lands
    # here on its way to the actual destination).
    flash.keep
    if user_has_assessments?
      redirect_to assessments_path
    else
      redirect_to frameworks_path
    end
  end

  private

  def user_has_assessments?
    return false unless current_person
    return true if PersonFrameworkAssignment.exists?(person_id: current_person.id)

    report_ids = current_person.direct_reports.pluck(:id)
    return false if report_ids.empty?

    PersonFrameworkAssignment.where(person_id: report_ids).exists?
  end
end
