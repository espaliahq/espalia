# frozen_string_literal: true

require "test_helper"
require "rake"

class AdminCreateTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["admin:create"].reenable
  end

  def run_task(**vars)
    old = vars.keys.index_with { ENV[it] }
    vars.each { |key, value| ENV[key] = value }
    capture_io { Rake::Task["admin:create"].invoke }.first
  ensure
    Rake::Task["admin:create"].reenable
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  should "promote an existing user, keeping their password when none is given" do
    user = create(:user, email: "member@example.com", password: "old-password-1", password_confirmation: "old-password-1", global_admin: false)

    output = run_task("EMAIL" => "Member@example.com ", "PASSWORD" => nil)

    assert user.reload.global_admin?
    assert user.valid_password?("old-password-1")
    assert_includes output, "existing password stands"
  end

  should "promote an existing user and change their password" do
    user = create(:user, email: "member@example.com", password: "old-password-1", password_confirmation: "old-password-1", global_admin: false)

    run_task("EMAIL" => "member@example.com", "PASSWORD" => "new-password-2")

    assert user.reload.global_admin?
    assert user.valid_password?("new-password-2")
  end

  should "create a global admin" do
    output = run_task("EMAIL" => "new-admin@example.com", "PASSWORD" => "new-password-2")

    user = User.find_by!(email: "new-admin@example.com")
    assert user.global_admin?
    assert user.valid_password?("new-password-2")
    assert_includes output, "Created global admin new-admin@example.com."
  end

  context "the audit" do
    should "record a promotion and a new admin as admin_task" do
      user = create(:user, email: "member@example.com")

      run_task("EMAIL" => "member@example.com", "PASSWORD" => nil)
      run_task("EMAIL" => "new-admin@example.com", "PASSWORD" => "new-password-2")

      created = User.find_by!(email: "new-admin@example.com")
      assert_equal [ [ true, "admin_task" ] ], GlobalAdminChange.where(user_id: user.id).pluck(:global_admin, :source)
      assert_equal [ [ true, "admin_task" ] ], GlobalAdminChange.where(user_id: created.id).pluck(:global_admin, :source)
    end

    should "record nothing when the account is already an admin" do
      create(:user, email: "member@example.com", global_admin: true)

      assert_no_difference -> { GlobalAdminChange.count } do
        run_task("EMAIL" => "member@example.com", "PASSWORD" => "new-password-2")
      end
    end
  end

  should "refuse to create a user without a password" do
    assert_raises(SystemExit) { run_task("EMAIL" => "new-admin@example.com", "PASSWORD" => nil) }

    assert_not User.exists?(email: "new-admin@example.com")
  end
end
