# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261127055717_create_global_admin_changes")

class CreateGlobalAdminChangesTest < ActiveSupport::TestCase
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { CreateGlobalAdminChanges.new.migrate(direction) }
  end

  def account(admin:)
    user = create(:user)
    User.where(id: user.id).update_all(global_admin: admin)
    user
  end

  should "give each account holding the flag one baseline row, and others none" do
    migrate(:down)
    holders = [ account(admin: true), account(admin: true) ]
    others = [ account(admin: false) ]

    migrate(:up)

    rows = ActiveRecord::Base.connection.select_rows("SELECT user_id, global_admin, source FROM global_admin_changes")
    assert_equal holders.map { [ it.id, true, "baseline" ] }.sort, rows.sort
    assert_not rows.any? { |user_id, *| others.map(&:id).include?(user_id) }
  ensure
    GlobalAdminChange.reset_column_information
  end
end
