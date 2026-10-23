# frozen_string_literal: true

# A person's own Auto / Light / Dark choice (#549). It lives on the global
# User so it follows them across tenants; Auto follows the operating system.
class AddColorSchemeToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :color_scheme, :string, default: "auto", null: false
  end
end
