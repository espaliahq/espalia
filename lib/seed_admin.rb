# frozen_string_literal: true

# The bootstrap global admin db/seeds.rb creates, with no credentials file
# involved: outside production a fixed dev-only admin, overridable anywhere
# via SEED_ADMIN_EMAIL / SEED_ADMIN_PASSWORD (a production first deploy sets
# them, or runs `bin/rails admin:create` afterwards). Once a global admin
# exists this is a no-op — one bootstrap, not a way to mint more admins.
class SeedAdmin
  DEV_EMAIL = "admin@example.com"
  DEV_PASSWORD = "password123"

  # @param env [ActiveSupport::StringInquirer]
  # @param output [IO]
  # @raise [ArgumentError] on a half-set override, or a first production
  #   deploy that sets nothing
  # @return [User] the global admin to seed tenants with
  def self.bootstrap!(env: Rails.env, output: $stdout)
    email = ENV["SEED_ADMIN_EMAIL"].presence&.downcase&.strip
    password = ENV["SEED_ADMIN_PASSWORD"].presence
    raise ArgumentError, "SEED_ADMIN_EMAIL is set but SEED_ADMIN_PASSWORD is not." if email && password.nil?

    unless env.production?
      email ||= DEV_EMAIL
      password ||= DEV_PASSWORD
    end

    if (user = email && User.find_by(email: email))
      unless user.global_admin?
        user.update!(global_admin: true)
        output.puts "Promoted #{user.email} to global admin"
      end
      output.puts "Admin user #{user.email} already exists"
      return user
    end

    # Production: one bootstrap, never a second admin minted by a later
    # SEED_ADMIN_EMAIL rotation. Development still creates its documented
    # dev admin beside whatever admins the database already holds.
    if env.production? && (existing = User.find_by(global_admin: true))
      output.puts "A global admin already exists (#{existing.email}); not creating another. Use bin/rails admin:create to add one."
      return existing
    end

    if email.nil?
      raise ArgumentError, "No global admin exists and SEED_ADMIN_EMAIL is not set. Set SEED_ADMIN_EMAIL and " \
                           "SEED_ADMIN_PASSWORD for the first deploy, or run bin/rails admin:create afterwards."
    end

    output.puts "Creating admin user: #{email}"
    user = User.create!(email: email, global_admin: true, password: password, password_confirmation: password)
    if env.production?
      output.puts "  Sign in with #{email} and the SEED_ADMIN_PASSWORD you set."
    else
      output.puts "  Sign in with #{email} / #{password}"
    end
    user
  end
end
