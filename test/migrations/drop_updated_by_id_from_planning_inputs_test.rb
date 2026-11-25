# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261125125310_drop_updated_by_id_from_planning_inputs")

class DropUpdatedByIdFromPlanningInputsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    migrate(:down)
    ActsAsTenant.with_tenant(@tenant) do
      @band = PayBand.create!(location: "Fixtureland", position: 1, currency: "AUD", period: "year",
                              minimum: 1, midpoint: 2, maximum: 3, role_name: "Every role", level_name: "Every level")
    end
  end

  teardown { DropUpdatedByIdFromPlanningInputs::TABLES.each { TenantPlanningInputs::Rows.model(it).reset_column_information } }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { DropUpdatedByIdFromPlanningInputs.new.migrate(direction) }
  end

  def column_left?(table) = ActiveRecord::Base.connection.column_exists?(table, :updated_by_id)

  should "refuse while a row still names an account, and leave the column as it is" do
    user = create(:user)
    PayBand.connection.execute(PayBand.sanitize_sql_array([ "UPDATE pay_bands SET updated_by_id = ? WHERE id = ?", user.id, @band.id ]))

    refused = assert_raises(ActiveRecord::MigrationError) { migrate(:up) }

    assert_match "pay_bands: 1", refused.message
    assert_match "events:reconcile", refused.message
    assert DropUpdatedByIdFromPlanningInputs::TABLES.all? { column_left?(it) }
  end

  should "drop the column, its index and its foreign key from each table once none names an account" do
    migrate(:up)

    DropUpdatedByIdFromPlanningInputs::TABLES.each do |table|
      assert_not column_left?(table), table
      assert_not ActiveRecord::Base.connection.foreign_key_exists?(table, :users), table
    end
  end

  should "restore the column, its index and its foreign key on the way down" do
    migrate(:up)
    migrate(:down)

    DropUpdatedByIdFromPlanningInputs::TABLES.each do |table|
      assert column_left?(table), table
      assert ActiveRecord::Base.connection.index_exists?(table, :updated_by_id), table
      assert ActiveRecord::Base.connection.foreign_key_exists?(table, :users, column: :updated_by_id), table
    end
  end
end
