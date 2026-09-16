# frozen_string_literal: true

# Tenant vocabulary — the word each performance state wears (#415).
#
# `show` renders the form; `update` persists via
# {Operations::Tenants::UpdateScoringVocabulary}. The controller authorizes
# against TenantPolicy in addition to the Operation's own policy check
# (defense in depth per docs/guidelines/authorization.md).
#
class Tenant::VocabulariesController < ApplicationController
  # GET /tenant/vocabulary
  def show
    authorize ActsAsTenant.current_tenant, :update_scoring_vocabulary?, policy_class: TenantPolicy
    render Views::Tenant::Vocabulary::EditView.new(
      tenant: ActsAsTenant.current_tenant,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants_for_user
    )
  end

  # PATCH /tenant/vocabulary
  def update
    authorize ActsAsTenant.current_tenant, :update_scoring_vocabulary?, policy_class: TenantPolicy

    Operations::Tenants::UpdateScoringVocabulary.call(
      context: pundit_user,
      params: vocabulary_params.to_h.symbolize_keys
    )
    redirect_to tenant_vocabulary_path, notice: "Vocabulary saved."
  rescue Operations::Base::ParameterError, ActiveRecord::RecordInvalid => e
    redirect_to tenant_vocabulary_path,
                alert: "Vocabulary could not be saved: #{error_message(e)}",
                status: :see_other
  end

  private

  def error_message(error)
    return error.record.errors.full_messages.to_sentence if error.respond_to?(:record)

    error.message
  end

  def vocabulary_params
    params.expect(tenant: [ :mastering_label ])
  end

  # @return [Array<Tenant>]
  def tenants_for_user
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
