# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

[ Rails.application.credentials.admin.user_1 ].each do |admin_user_credentials|
  admin_user = User.where(email: admin_user_credentials.email).first
  if admin_user.nil?
    puts "Creating admin user: #{admin_user_credentials.email}"
    admin_user = User.new(
      email: admin_user_credentials.email,
      # name: admin_user_credentials.name,
      global_admin: true,
      password: admin_user_credentials.password,
      password_confirmation: admin_user_credentials.password
    )
    admin_user.save!
  else
    puts "Admin user #{admin_user_credentials.email} already exists"
  end

  [ { slug: "meandu", name: "me&u" }, { slug: "testco", name: "Testco" } ].each do |tenant_attrs|
    # Create the "me&u" tenant and assign the admin user
    tenant = Tenant.find_or_create_by!(slug: tenant_attrs[:slug]) do |t|
      t.name = tenant_attrs[:name]
      puts "Creating tenant: #{tenant_attrs[:name]}"
    end

    ActsAsTenant.with_tenant(tenant) do
      unless TenantUser.exists?(user: admin_user)
        TenantUser.create!(tenant: tenant, user: admin_user, role: :admin)
        puts "Assigned #{admin_user.email} to tenant #{tenant_attrs[:name]} as admin"
      else
        puts "#{admin_user.email} already assigned to tenant #{tenant_attrs[:name]}"
      end
    end
  end
end
