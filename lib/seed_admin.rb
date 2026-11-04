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
    raise ArgumentError, "SEED_ADMIN_PASSWORD is set but SEED_ADMIN_EMAIL is not." if password && email.nil?

    dev_default_password = false
    unless env.production?
      email ||= DEV_EMAIL
      if password.nil?
        password = DEV_PASSWORD
        dev_default_password = true
      end
    end

    # Production: one bootstrap, never a second admin minted (or a demoted
    # account re-promoted) by a lingering SEED_ADMIN_EMAIL. Development still
    # creates its documented dev admin beside whatever the database holds.
    if env.production? && (existing = User.where(global_admin: true).order(:created_at, :id).first)
      output.puts "Admin user #{existing.email} already exists"
      return existing
    end

    if (user = email && User.find_by(email: email))
      unless user.global_admin?
        user.update!(global_admin: true)
        output.puts "Promoted #{user.email} to global admin"
      end
      output.puts "Admin user #{user.email} already exists"
      return user
    end

    if email.nil?
      raise ArgumentError, "No global admin exists and SEED_ADMIN_EMAIL is not set. Set SEED_ADMIN_EMAIL and " \
                           "SEED_ADMIN_PASSWORD for the first deploy, or run bin/rails admin:create afterwards."
    end

    output.puts "Creating admin user: #{email}"
    user = User.create!(email: email, global_admin: true, password: password, password_confirmation: password)
    # A supplied password is never printed, whatever the environment — only
    # the fixed, documented dev default is safe to echo.
    if dev_default_password
      output.puts "  Sign in with #{email} / #{password}"
    else
      output.puts "  Sign in with #{email} and the SEED_ADMIN_PASSWORD you set."
    end
    user
  end
end
