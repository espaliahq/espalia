class AddDepartmentToFrameworkRoleFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :framework_role_families, :department, :string
  end
end
