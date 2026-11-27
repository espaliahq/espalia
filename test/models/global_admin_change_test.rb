# frozen_string_literal: true

require "test_helper"

class GlobalAdminChangeTest < ActiveSupport::TestCase
  def changes_for(user) = GlobalAdminChange.where(user_id: user.id).order(:created_at, :id)

  context "a save that changes global_admin" do
    should "record a new admin" do
      user = User.create!(email: "new@example.com", password: "password123", global_admin: true, global_admin_source: "console")

      assert_equal [ [ true, "console" ] ], changes_for(user).pluck(:global_admin, :source)
    end

    should "record a promotion and a demotion" do
      user = create(:user)

      user.update!(global_admin: true, global_admin_source: "seed")
      user.update!(global_admin: false, global_admin_source: "console")

      assert_equal [ [ true, "seed" ], [ false, "console" ] ], changes_for(user).pluck(:global_admin, :source)
    end

    should "record nothing when the flag is unchanged" do
      user = create(:user, global_admin: true)

      assert_no_difference -> { GlobalAdminChange.count } do
        user.update!(email: "renamed@example.com")
        user.update!(global_admin: true)
      end
    end

    should "record one change when a stale copy saves the same flag" do
      user = create(:user)
      stale = User.find(user.id)

      user.update!(global_admin: true, global_admin_source: "console")
      stale.update!(global_admin: true, global_admin_source: "console")

      assert_equal [ [ true, "console" ] ], changes_for(user).pluck(:global_admin, :source)
    end

    should "record one change when a stale copy saves the same demotion" do
      user = create(:user, global_admin: true)
      stale = User.find(user.id)

      user.update!(global_admin: false, global_admin_source: "console")
      stale.update!(global_admin: false, global_admin_source: "console")

      assert_equal [ [ true, "seed" ], [ false, "console" ] ], changes_for(user).pluck(:global_admin, :source)
    end

    should "still refuse a stale copy's change that names no source" do
      user = create(:user)
      stale = User.find(user.id)
      user.update!(global_admin: true, global_admin_source: "console")

      assert_raises(ActiveRecord::RecordInvalid) { stale.update!(global_admin: true) }
      stale.global_admin = true
      assert_raises(User::GlobalAdminSourceMissing) { stale.save(validate: false) }
      assert_equal 1, changes_for(user).count
    end

    should "record a demotion saved by a copy reloaded after the promotion" do
      user = create(:user)
      copy = User.find(user.id)

      user.update!(global_admin: true, global_admin_source: "console")
      copy.reload
      copy.update!(global_admin: false, global_admin_source: "console")

      assert_equal [ [ true, "console" ], [ false, "console" ] ], changes_for(user).pluck(:global_admin, :source)
    end

    should "not carry the stored flag from a failed save into a copy" do
      user = create(:user)
      user.assign_attributes(global_admin: true, global_admin_source: "console")
      user.instance_variable_set(:@global_admin_stored, true)

      copy = user.dup
      copy.assign_attributes(email: "copy@example.com", global_admin_source: "console")
      copy.save!

      assert_equal [ [ true, "console" ] ], changes_for(copy).pluck(:global_admin, :source)
    end

    should "refuse to record a change for an account deleted before the save" do
      user = create(:user)
      User.where(id: user.id).delete_all

      assert_raises(ActiveRecord::RecordNotFound) { user.update!(global_admin: true, global_admin_source: "console") }
      assert_empty changes_for(user)
    end

    should "lock the account's row while it changes the flag" do
      user = create(:user)
      user.assign_attributes(global_admin: true, global_admin_source: "console")

      queries = []
      callback = ->(*, payload) { queries << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { user.save! }

      assert queries.any? { it.match?(/FROM "users".*FOR UPDATE/m) }
    end

    should "record nothing for an account created without the flag" do
      assert_no_difference -> { GlobalAdminChange.count } do
        create(:user)
      end
    end
  end

  context "a change with no stated source" do
    should "refuse, say how to name one, and leave the flag and the audit as they were" do
      user = create(:user)

      assert_not user.update(global_admin: true)

      assert_match(/one of admin_task, seed, console/, user.errors[:global_admin_source].sole)
      assert_not user.reload.global_admin?
      assert_empty changes_for(user)
    end

    should "write nothing when a caller rescues the refusal inside its own transaction" do
      user = create(:user)

      User.transaction do
        user.update!(global_admin: true)
      rescue ActiveRecord::RecordInvalid
        nil
      end

      assert_not user.reload.global_admin?
      assert_empty changes_for(user)
    end

    should "refuse a save that skips validation before writing, even when the caller rescues it" do
      user = create(:user)
      user.global_admin = true

      User.transaction do
        error = assert_raises(User::GlobalAdminSourceMissing) { user.save(validate: false) }
        assert_match(/set global_admin_source to one of admin_task, seed, console/, error.message)
      end

      assert_not user.reload.global_admin?
      assert_empty changes_for(user)
    end

    should "refuse a source outside the list before writing, when a save inside a transaction skips validation" do
      user = create(:user)
      user.assign_attributes(global_admin: true, global_admin_source: "baseline")

      User.transaction do
        assert_raises(User::GlobalAdminSourceMissing) { user.save(validate: false) }
      end

      assert_not user.reload.global_admin?
      assert_empty changes_for(user)
    end

    should "need naming again for each change" do
      user = create(:user)
      user.update!(global_admin: true, global_admin_source: "console")

      assert_raises(ActiveRecord::RecordInvalid) { user.update!(global_admin: false) }
      assert user.reload.global_admin?
    end

    should "not carry a source past a reload after a refused save" do
      user = create(:user)
      assert_not user.update(global_admin: true, global_admin_source: "seed", email: "")

      user.reload
      assert_raises(ActiveRecord::RecordInvalid) { user.update!(global_admin: true) }
      assert_not user.reload.global_admin?
    end

    should "not carry a source past a save that failed on another attribute, even without a reload" do
      user = create(:user)
      assert_not user.update(global_admin: true, global_admin_source: "seed", email: "")

      assert_not user.update(email: "kept@example.com")
      assert_includes user.errors.attribute_names, :global_admin_source
      assert_not user.reload.global_admin?
      assert_empty changes_for(user)
    end

    should "report a blank source once" do
      user = create(:user)

      assert_not user.update(global_admin: true, global_admin_source: "")
      assert_match(/one of admin_task, seed, console/, user.errors[:global_admin_source].sole)
    end

    should "say a named source is not one the audit records when a save skips validation" do
      user = create(:user)
      user.assign_attributes(global_admin: true, global_admin_source: "baseline")

      error = assert_raises(User::GlobalAdminSourceMissing) { user.save(validate: false) }
      assert_match(/"baseline" is not a source the audit records/, error.message)
    end

    should "not carry a source named for a save that left the flag alone" do
      user = create(:user, global_admin: true)
      user.update!(global_admin: true, global_admin_source: "seed")

      assert_raises(ActiveRecord::RecordInvalid) { user.update!(global_admin: false) }
      assert user.reload.global_admin?
    end
  end

  should "refuse baseline and any source outside the list" do
    user = create(:user)

    %w[baseline unknown].each do |source|
      assert_raises(ActiveRecord::RecordInvalid) { user.update!(global_admin: true, global_admin_source: source) }
      assert_not user.reload.global_admin?
    end
    assert_empty changes_for(user)
  end

  should "say why a plain save refuses a source outside the list" do
    user = create(:user)

    assert_not user.update(global_admin: true, global_admin_source: "Console")
    assert_includes user.errors.attribute_names, :global_admin_source
    assert_not user.reload.global_admin?
  end

  should "refuse a baseline row written through the model" do
    assert_raises(ActiveRecord::RecordInvalid) do
      GlobalAdminChange.create!(user_id: SecureRandom.uuid_v7, global_admin: true, source: "baseline")
    end
  end

  should "keep a row unchanged once saved" do
    row = changes_for(create(:user, global_admin: true)).sole

    assert_raises(ActiveRecord::ReadOnlyRecord) { row.update!(source: "console") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.destroy! }
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.delete }
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.update_column(:source, "console") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.update_columns(source: "console", global_admin: false) }
    assert_equal "seed", row.reload.source
  end

  should "hold the account id, the new value, the source and the time, and nothing else" do
    assert_equal %w[created_at global_admin id source user_id], GlobalAdminChange.column_names.sort
    assert_empty ActiveRecord::Base.connection.foreign_keys(:global_admin_changes)
  end
end
