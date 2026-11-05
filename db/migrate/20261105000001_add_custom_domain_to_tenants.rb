# frozen_string_literal: true

# A tenant's own sign-on host (#660): a full domain or a subdomain. A request
# arriving on it assumes the tenant — branding pre-auth, session scoping after.
class AddCustomDomainToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :custom_domain, :string
    add_index :tenants, :custom_domain, unique: true
  end
end
