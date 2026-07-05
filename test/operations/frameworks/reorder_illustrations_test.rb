# frozen_string_literal: true

require "test_helper"

# Reordering is a direct, shape-preserving structural edit (edit-rights bar):
# the Operation takes the complete ordered id list and refuses anything that
# isn't an exact permutation of the expectation × role's illustrations —
# a foreign / missing / duplicated id must classify as a parameter error,
# never renumber another expectation's illustrations.
class Operations::Frameworks::ReorderIllustrationsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      @expectation_id = SecureRandom.uuid_v7
      @ill_a = SecureRandom.uuid_v7
      @ill_b = SecureRandom.uuid_v7
      @ill_c = SecureRandom.uuid_v7
      @other_ill = SecureRandom.uuid_v7

      h = Frameworks::CommandHandler.new
      h.create_framework(@framework_id, "Eng")
      rfid = SecureRandom.uuid_v7
      h.add_role_family(@framework_id, rfid, "Engineering")
      h.add_role(@framework_id, @role_id, rfid, "Software Engineer", "E", "ic")
      h.add_level(@framework_id, SecureRandom.uuid_v7, @role_id, 1, "E1", "E1")
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      other_expectation = SecureRandom.uuid_v7
      h.add_capability_category(@framework_id, cat_id, "Thinking")
      h.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      h.set_behavioural_expectation(@framework_id, @expectation_id, SecureRandom.uuid_v7, cap_id, 1, "Asks questions")
      h.add_role_illustration(@framework_id, @ill_a, SecureRandom.uuid_v7, @expectation_id, @role_id, 1, "First")
      h.add_role_illustration(@framework_id, @ill_b, SecureRandom.uuid_v7, @expectation_id, @role_id, 2, "Second")
      h.add_role_illustration(@framework_id, @ill_c, SecureRandom.uuid_v7, @expectation_id, @role_id, 3, "Third")
      # A second expectation with its own illustration — must never be
      # renumbered by a reorder on the first expectation.
      cap2 = SecureRandom.uuid_v7
      h.add_capability(@framework_id, cap2, SecureRandom.uuid_v7, cat_id, "Critical Thinking")
      h.set_behavioural_expectation(@framework_id, other_expectation, SecureRandom.uuid_v7, cap2, 1, "Weighs options")
      h.add_role_illustration(@framework_id, @other_ill, SecureRandom.uuid_v7, other_expectation, @role_id, 1, "Elsewhere")
      h.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: @admin_person)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def ordered_ids
    FrameworkState::RoleIllustration
      .where(expectation_id: @expectation_id, role_id: @role_id)
      .order(:ordinal, :id).pluck(:illustration_id)
  end

  context "as tenant admin" do
    should "reorder the illustrations and renumber ordinals" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::ReorderIllustrations.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, expectation_id: @expectation_id,
                    role_id: @role_id, new_ordering: [ @ill_c, @ill_a, @ill_b ] }
        )

        assert_equal [ @ill_c, @ill_a, @ill_b ], result[:new_ordering]
        assert_equal [ @ill_c, @ill_a, @ill_b ], ordered_ids
        assert_equal [ 1, 2, 3 ],
                     FrameworkState::RoleIllustration.where(illustration_id: [ @ill_c, @ill_a, @ill_b ])
                       .order(:ordinal).pluck(:ordinal)
      end
    end

    should "reject an ordering that is not a permutation" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::ReorderIllustrations.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, expectation_id: @expectation_id,
                      role_id: @role_id, new_ordering: [ @ill_a, @ill_b ] } # missing one
          )
        end
      end
    end

    should "reject an ordering that smuggles another expectation's illustration" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::ReorderIllustrations.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, expectation_id: @expectation_id,
                      role_id: @role_id, new_ordering: [ @other_ill, @ill_a, @ill_b ] }
          )
        end
        assert_equal 1, FrameworkState::RoleIllustration.find_by(illustration_id: @other_ill).ordinal
      end
    end
  end

  context "as plain member (no edit rights)" do
    should "deny the reorder" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::ReorderIllustrations.call(
            context: @member_ctx,
            params: { framework_id: @framework_id, expectation_id: @expectation_id,
                      role_id: @role_id, new_ordering: [ @ill_c, @ill_a, @ill_b ] }
          )
        end
      end
    end
  end
end
