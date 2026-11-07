# frozen_string_literal: true

require "test_helper"

# The tenant's words for the performance states (#415). The scoring states
# themselves are untouched — this only moves the label.
class Operations::Tenants::UpdateScoringVocabularyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    @tenant_user = ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @user, role: :admin)
    end
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
  end

  def call(params)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Tenants::UpdateScoringVocabulary.call(context: @context, params: params)
    end
  end

  context "writing a label" do
    should "rename the state for this tenant and report how it now reads" do
      result = call(mastering_label: "Advancing")

      assert_equal [ :mastering_label ], result[:updated]
      assert_equal "Advancing", result.dig(:labels, :mastering)
      assert_equal "Advancing", @tenant.reload.mastering_label
    end

    should "leave every other tenant alone" do
      other = create(:tenant)
      call(mastering_label: "Advancing")

      assert_equal "Mastering", Views::Assessments::StateLabels.for(:mastering, tenant: other)
    end

    should "strip surrounding whitespace" do
      call(mastering_label: "  Advancing  ")

      assert_equal "Advancing", @tenant.reload.mastering_label
    end
  end

  context "clearing a label" do
    should "fall back to the word Espalia ships" do
      call(mastering_label: "Advancing")
      result = call(mastering_label: "")

      assert_nil @tenant.reload.mastering_label.presence
      assert_equal "Mastering", result.dig(:labels, :mastering)
    end

    should "treat whitespace as blank rather than storing an empty badge" do
      call(mastering_label: "Advancing")
      call(mastering_label: "   ")

      assert_equal "Mastering", Views::Assessments::StateLabels.for(:mastering, tenant: @tenant.reload)
    end
  end

  context "an over-long label" do
    should "be refused at the boundary, so MCP reads it as invalid input" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(mastering_label: "A" * 25)
      end

      assert_match(/mastering_label/, error.message)
      assert_match(/24 characters/, error.message)
      assert_nil @tenant.reload.mastering_label.presence
    end
  end

  context "authorization" do
    should "refuse a member who is not an admin" do
      member = create(:user)
      tenant_user = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: member, role: :member)
      end
      context = AuthorizationContext.new(user: member, tenant_user: tenant_user, person: nil)

      assert_raises(Pundit::NotAuthorizedError) do
        ActsAsTenant.with_tenant(@tenant) do
          Operations::Tenants::UpdateScoringVocabulary.call(
            context: context, params: { mastering_label: "Advancing" }
          )
        end
      end
    end
  end
end
