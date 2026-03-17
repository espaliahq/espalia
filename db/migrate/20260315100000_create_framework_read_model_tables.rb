# frozen_string_literal: true

class CreateFrameworkReadModelTables < ActiveRecord::Migration[8.0]
  def change
    create_table :framework_role_families, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :framework_id, null: false
      t.uuid :role_family_id, null: false
      t.string :name, null: false
      t.text :description
      t.timestamps
    end

    add_index :framework_role_families, [ :tenant_id, :role_family_id ], unique: true
    add_index :framework_role_families, [ :tenant_id, :framework_id ]

    create_table :framework_roles, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :role_family_id, null: false
      t.uuid :role_id, null: false
      t.string :name, null: false
      t.string :code, null: false
      t.string :track, null: false
      t.timestamps
    end

    add_index :framework_roles, [ :tenant_id, :role_id ], unique: true

    create_table :framework_levels, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :role_id, null: false
      t.uuid :level_id, null: false
      t.integer :ordinal, null: false
      t.string :title, null: false
      t.string :code, null: false
      t.boolean :is_entry, default: false, null: false
      t.timestamps
    end

    add_index :framework_levels, [ :tenant_id, :level_id ], unique: true
    add_index :framework_levels, [ :tenant_id, :role_id, :ordinal ], unique: true

    create_table :framework_capability_categories, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :framework_id, null: false
      t.uuid :category_id, null: false
      t.string :name, null: false
      t.text :description
      t.integer :ordinal
      t.decimal :category_tolerance, precision: 5, scale: 2, null: true
      t.timestamps
    end

    add_index :framework_capability_categories, [ :tenant_id, :category_id ], unique: true,
              name: :idx_fw_cap_categories_on_tenant_and_category

    create_table :framework_capabilities, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :category_id, null: false
      t.uuid :capability_id, null: false
      t.uuid :stable_id, null: false
      t.string :name, null: false
      t.text :description
      t.string :status, null: false, default: "active"
      t.timestamps
    end

    add_index :framework_capabilities, [ :tenant_id, :capability_id ], unique: true
    add_index :framework_capabilities, [ :tenant_id, :stable_id ]

    create_table :framework_capability_role_bindings, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :binding_id, null: false
      t.uuid :capability_id, null: false
      t.uuid :role_id, null: false
      t.decimal :weight, precision: 5, scale: 2, default: 1.0, null: false
      t.decimal :individual_tolerance, precision: 5, scale: 2, null: true
      t.timestamps
    end

    add_index :framework_capability_role_bindings, [ :tenant_id, :binding_id ], unique: true,
              name: :idx_fw_cap_role_bindings_on_tenant_and_binding
    add_index :framework_capability_role_bindings, [ :tenant_id, :capability_id, :role_id ], unique: true,
              name: :idx_fw_cap_role_bindings_on_tenant_cap_role

    create_table :framework_behavioural_expectations, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :expectation_id, null: false
      t.uuid :stable_id, null: false
      t.uuid :capability_id, null: false
      t.integer :level_ordinal, null: false
      t.text :description, null: false
      t.timestamps
    end

    add_index :framework_behavioural_expectations, [ :tenant_id, :expectation_id ], unique: true,
              name: :idx_fw_behav_expectations_on_tenant_and_expectation
    add_index :framework_behavioural_expectations, [ :tenant_id, :capability_id, :level_ordinal ], unique: true,
              name: :idx_fw_behav_expectations_on_tenant_cap_level

    create_table :framework_role_illustrations, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :illustration_id, null: false
      t.uuid :stable_id, null: false
      t.uuid :expectation_id, null: false
      t.uuid :role_id, null: false
      t.integer :ordinal, null: false
      t.text :description, null: false
      t.timestamps
    end

    add_index :framework_role_illustrations, [ :tenant_id, :illustration_id ], unique: true,
              name: :idx_fw_role_illustrations_on_tenant_and_illustration
    add_index :framework_role_illustrations, [ :tenant_id, :expectation_id, :role_id ],
              name: :idx_fw_role_illustrations_on_tenant_exp_role
  end
end
