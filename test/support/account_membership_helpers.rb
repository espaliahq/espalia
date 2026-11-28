# frozen_string_literal: true

# Memberships for the admin task and seed tests, which decide on whether an account is held.
module AccountMembershipHelpers
  def member(user)
    tenant = create(:tenant)
    ActsAsTenant.with_tenant(tenant) { create(:tenant_user, tenant:, user:) }
    user
  end

  # The lookup sees the membership; the lock finds it forgotten.
  def forgotten_once_locked(user, &)
    membership = TenantUser.unscoped.find_by!(user_id: user.id)
    user.define_singleton_method(:lock!) do |*args|
      TenantUser.unscoped.where(id: membership.id).update_all(forgotten_at: Time.current, user_id: nil)
      super(*args)
    end
    User.stub(:find_by, user, &)
  end
end
