# frozen_string_literal: true

# The tenant's approved headcount budget (Team Planning 6.1), which every plan
# starts from. Tenant admins only. A refused form is shown again with what was
# typed, so nothing has to be entered twice.
class Tenant::BudgetLinesController < ApplicationController
  include BudgetLineForm

  # GET /tenant/budget_lines
  def index
    authorize_budget
    render_index
  end

  # POST /tenant/budget_lines
  def create
    authorize_budget
    line = Operations::Tenants::AddBudgetLine.call(context: pundit_user, params: operation_params)
    redirect_to tenant_budget_lines_path, notice: "Budget line added for #{role_text(line)}.", status: :see_other
  rescue Operations::Base::ParameterError => e
    flash.now[:alert] = "The budget line could not be added: #{e.message}."
    render_index(draft: line_params, status: :unprocessable_content)
  end

  # GET /tenant/budget_lines/:id/edit
  def edit
    authorize_budget
    render_edit(line_payload)
  end

  # PATCH /tenant/budget_lines/:id
  def update
    authorize_budget
    line = Operations::Tenants::ChangeBudgetLine.call(context: pundit_user, params: operation_params.merge(budget_line_id: params[:id]))
    redirect_to tenant_budget_lines_path, notice: "Budget line changed for #{role_text(line)}.", status: :see_other
  rescue Operations::Base::ParameterError => e
    flash.now[:alert] = "The budget line could not be changed: #{e.message}."
    render_edit(line_payload.merge(line_params), status: :unprocessable_content)
  end

  # DELETE /tenant/budget_lines/:id
  def destroy
    authorize_budget
    line = Operations::Tenants::RemoveBudgetLine.call(context: pundit_user, params: { budget_line_id: params[:id] })
    redirect_to tenant_budget_lines_path, notice: "Budget line removed for #{line[:role] || 'any role'}.", status: :see_other
  rescue Operations::Base::ParameterError => e
    redirect_to tenant_budget_lines_path, alert: "The budget line could not be removed: #{e.message}.", status: :see_other
  end

  private

  def authorize_budget
    authorize ActsAsTenant.current_tenant, :manage_budget_lines?, policy_class: TenantPolicy
  end

  def render_index(draft: {}, status: :ok)
    render Views::Tenant::BudgetLines::IndexView.new(
      lines: Operations::Tenants::BudgetLines.call(context: pundit_user, params: {})[:budget_lines],
      roles:, countries: PayBand.known_countries, draft:, **shell
    ), status:
  end

  def render_edit(line, status: :ok)
    render Views::Tenant::BudgetLines::EditView.new(line:, roles:, countries: PayBand.known_countries, **shell), status:
  end

  def roles = FrameworkState::Role.includes(:levels).order(:name).to_a

  def shell
    { user: current_user, current_tenant: ActsAsTenant.current_tenant,
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a } }
  end

  # @raise [ActiveRecord::RecordNotFound] for a line this tenant doesn't hold, which renders a 404
  def line_payload
    Operations::Tenants::BudgetLines.call(context: pundit_user, params: { budget_line_id: params[:id] })[:budget_lines].sole
  rescue Operations::Base::ParameterError
    raise ActiveRecord::RecordNotFound
  end

  def role_text(line) = [ line[:role], line[:level_name] ].compact.join(", ").presence || "any role"
end
