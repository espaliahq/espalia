# frozen_string_literal: true

# The "How assessments work" guide: one page walking a person through a
# cycle, from setup to a concluded, aligned record.
class AssessmentGuidesController < ApplicationController
  # GET /assessments/how-it-works
  def show
    authorize :assessment_guide, :show?
    @page_title = "How assessments work"

    render Views::AssessmentGuides::ShowView.new(
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  private

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
