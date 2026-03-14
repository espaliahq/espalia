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

  [
    { slug: "meandu", name: "me&u", primary_color: "#00362F", secondary_color: "#001814",
      nav_bg_color: "#DBFC45", nav_fg_color: "#001814", font_family: "Syne" },
    { slug: "testco", name: "Testco", primary_color: "#6366f1", secondary_color: "#4f46e5",
      nav_bg_color: "#1e1b4b", nav_fg_color: "#e0e7ff", font_family: "Poppins" }
  ].each do |tenant_attrs|
    theme_keys = %i[primary_color secondary_color nav_bg_color nav_fg_color font_family]

    tenant = Tenant.find_or_create_by!(slug: tenant_attrs[:slug]) do |t|
      t.name = tenant_attrs[:name]
      theme_keys.each { |k| t.public_send(:"#{k}=", tenant_attrs[k]) }
      puts "Creating tenant: #{tenant_attrs[:name]}"
    end

    # Update theme on existing tenants
    if theme_keys.any? { |k| tenant.public_send(k) != tenant_attrs[k] }
      tenant.update!(tenant_attrs.slice(*theme_keys))
      puts "Updated theme for #{tenant_attrs[:name]}"
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
