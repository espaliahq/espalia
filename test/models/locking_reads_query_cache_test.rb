# frozen_string_literal: true

require "test_helper"

# A locking select must reach the database even while Rails' query cache
# holds the same query: served from the cache, it would take no lock and
# could answer with a row another session has since changed. Each change
# here is written below Active Record, so the cache never hears of it.
class LockingReadsQueryCacheTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @person = create(:person, tenant: @tenant)
  end

  should "refuse a person forgotten since the refusal last read their row" do
    ActiveRecord::Base.cache do
      PersonDevelopment::ForgottenSubject.refuse!(@person.id)
      raw_sql("UPDATE people SET forgotten_at = now(), name = 'Former member', email = NULL WHERE id = $1", @person.id)

      assert_raises(PersonDevelopment::ForgottenSubject::Forgotten) { PersonDevelopment::ForgottenSubject.refuse!(@person.id) }
    end
  end

  should "send a grant's hold on the person's row to the database each time" do
    grants = AccountGrants::CommandHandler.new

    ActiveRecord::Base.cache do
      grants.send(:hold_person, @person.id)

      assert_equal 1, locking_selects { grants.send(:hold_person, @person.id) }
    end
  end

  should "send a grant's hold on the tenant's accounts to the database each time, seeing an account added since" do
    grants = AccountGrants::CommandHandler.new
    ActsAsTenant.with_tenant(@tenant) do
      ActiveRecord::Base.cache do
        assert_empty grants.send(:hold_live_accounts)
        account = create(:tenant_user, tenant: @tenant)

        assert_equal 1, locking_selects { assert_equal [ account.id ], grants.send(:hold_live_accounts) }
      end
    end
  end

  should "audit a change to global admin against the flag as stored, not as the cache last read it" do
    user = create(:user)

    ActiveRecord::Base.cache do
      User.where(id: user.id).lock.pick(:global_admin)
      raw_sql("UPDATE users SET global_admin = true WHERE id = $1", user.id)

      assert_no_difference -> { GlobalAdminChange.where(user_id: user.id).count } do
        user.update!(global_admin: true, global_admin_source: "console")
      end
    end
  end

  private

  def raw_sql(sql, *binds) = ActiveRecord::Base.connection.raw_connection.exec_params(sql, binds)

  def locking_selects
    count = 0
    counter = ->(*, payload) { count += 1 if payload[:sql].include?("FOR ") && !payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end
end
