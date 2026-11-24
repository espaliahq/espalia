# frozen_string_literal: true

# Tenant user management — list, view, and update tenant memberships.
#
# Lets tenant administrators see every TenantUser in the current tenant,
# flip their tenant role (member ↔ admin), and drill into a user's
# framework collaborator assignments across all frameworks in the tenant.
#
# Access is gated by TenantUserPolicy — tenant admins and global admins only.
#
class Tenant::UsersController < ApplicationController
  before_action :set_tenant_user, only: [ :show, :update, :collaborator_scope_picker ]

  # GET /tenant/users
  def index
    authorize TenantUser, :index?
    @tenant_users = TenantUser.includes(:user, :person).order(:created_at).to_a
    render Views::Tenant::Users::IndexView.new(
      tenant_users: @tenant_users,
      collaborator_counts: collaborator_counts_for(@tenant_users),
      impersonatable_ids: impersonatable_ids(@tenant_users),
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants_for_user
    )
  end

  # GET /tenant/users/:id
  def show
    authorize @tenant_user
    person = @tenant_user.ensure_person!
    collaborators = FrameworkState::Collaborator
      .for_person(person.id)
      .order(:framework_id, :role)
      .to_a
    frameworks = FrameworkState::Framework.all.to_a
    render Views::Tenant::Users::ShowView.new(
      tenant_user: @tenant_user,
      person: person,
      collaborator_rows: TenantUserCollaboratorRow.build_many(collaborators, frameworks),
      frameworks: frameworks,
      last_admin: last_admin?(@tenant_user),
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants_for_user
    )
  end

  # GET /tenant/users/:id/collaborator_scope_picker
  #
  # Turbo Frame fragment re-rendered when the assignment form's framework
  # or role select changes. Returns the scope-entity dropdown appropriate
  # for the chosen framework + role combination, or an empty fragment for
  # framework-wide roles.
  def collaborator_scope_picker
    authorize @tenant_user, :collaborator_scope_picker?
    framework = framework_for_scope_picker
    role = params[:role].to_s
    render Views::Tenant::Users::ScopePickerFrame.new(
      framework: framework, role: role
    )
  end

  # PATCH /tenant/users/:id
  def update
    authorize @tenant_user
    new_role = params.expect(tenant_user: [ :role ])[:role].to_s

    unless TenantUser.roles.key?(new_role)
      return redirect_to tenant_user_path(@tenant_user),
                         alert: "Invalid tenant role.",
                         status: :see_other
    end

    person = @tenant_user.ensure_person!
    Operations::Tenants::SetAccountRole.call(context: pundit_user, params: { person_id: person.id, role: new_role })
    redirect_to tenant_user_path(@tenant_user), notice: "Tenant role updated.", status: :see_other
  rescue Operations::Base::ParameterError => e
    redirect_to tenant_user_path(@tenant_user), alert: "The role could not be changed: #{e.message.sub(/\A\w+: /, '')}.",
                                                status: :see_other
  end

  private

  def set_tenant_user
    @tenant_user = TenantUser.find(params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    redirect_to tenant_users_path
  end

  def framework_for_scope_picker
    return nil if params[:framework_id].blank?

    FrameworkState::Framework.find_by(framework_id: params[:framework_id])
  end

  # Counts of framework collaborator rows per linked person, so the index
  # avoids an N+1 over @tenant_users.
  #
  # @param tenant_users [Enumerable<TenantUser>]
  # @return [Hash{String => Integer}] person_id → count
  # Ids of memberships the acting admin may "view as", per
  # {ImpersonationPolicy}. Evaluated against {Impersonatable#real_context}
  # so the affordance reflects the admin's own authority. Returned as a Set
  # of TenantUser ids for O(1) lookup in the view.
  #
  # @param tenant_users [Enumerable<TenantUser>]
  # @return [Set<String>]
  def impersonatable_ids(tenant_users)
    ctx = real_context
    tenant_users.each_with_object(Set.new) do |tu, set|
      set << tu.id if ImpersonationPolicy.new(ctx, tu).create?
    end
  end

  def collaborator_counts_for(tenant_users)
    person_ids = tenant_users.map(&:person_id).compact
    return {} if person_ids.empty?

    FrameworkState::Collaborator.where(person_id: person_ids).group(:person_id).count
  end

  def last_admin?(tenant_user)
    tenant_user.admin? && TenantUser.where(role: :admin).count <= 1
  end

  # @return [Array<Tenant>]
  def tenants_for_user
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
