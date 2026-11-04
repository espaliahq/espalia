# frozen_string_literal: true

# The bootstrap global admin db/seeds.rb creates, with no credentials file
# involved: outside production a fixed dev-only admin, overridable anywhere
# via SEED_ADMIN_EMAIL / SEED_ADMIN_PASSWORD (a production first deploy sets
# them, or runs `bin/rails admin:create` afterwards). An existing admin makes
# this a no-op, so established deployments need nothing.
class SeedAdmin
  DEV_EMAIL = "admin@example.com"
  DEV_PASSWORD = "password123"

  # @param env [ActiveSupport::StringInquirer]
  # @param output [IO]
  # @raise [ArgumentError] when production has no admin and no SEED_ADMIN_* set
  # @return [User] the global admin to seed tenants with
  def self.bootstrap!(env: Rails.env, output: $stdout)
    email = ENV["SEED_ADMIN_EMAIL"].presence
    password = ENV["SEED_ADMIN_PASSWORD"].presence
    unless env.production?
      email ||= DEV_EMAIL
      password ||= DEV_PASSWORD
    end

    user = email ? User.find_by(email: email) : User.find_by(global_admin: true)
    if user
      output.puts "Admin user #{user.email} already exists"
      return user
    end

    if email.nil?
      raise ArgumentError, "No global admin exists and SEED_ADMIN_EMAIL is not set. Set SEED_ADMIN_EMAIL and " \
                           "SEED_ADMIN_PASSWORD for the first deploy, or run bin/rails admin:create afterwards."
    end
    raise ArgumentError, "SEED_ADMIN_EMAIL is set but SEED_ADMIN_PASSWORD is not." if password.nil?

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
