class AddStatusAndDepartmentToPeople < ActiveRecord::Migration[8.1]
  def change
    add_column :people, :status, :string, null: false, default: "active"
    add_column :people, :department, :string
    add_column :people, :hris_raw_data, :jsonb
    add_index :people, [ :tenant_id, :status ]
  end
end
