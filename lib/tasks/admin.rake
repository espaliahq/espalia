# frozen_string_literal: true

namespace :admin do
  # The password comes from the environment so it stays out of the command
  # line, process listings and shell history: `IFS= read -rs PASSWORD && export PASSWORD`.
  desc "Create or promote a global admin: EMAIL=who@example.com bin/rails admin:create (PASSWORD from the environment)"
  task create: :environment do
    email = ENV["EMAIL"].presence&.downcase&.strip or abort "Set EMAIL (and PASSWORD for a new user)."
    password = ENV["PASSWORD"].presence

    user = User.find_by(email: email)
    if user
      message = User.transaction do
        if user.lock!(User::CREDENTIALS_LOCK).unvouched?
          if password.nil?
            abort "#{email} has an account with no tenant membership that isn't a global admin. Give PASSWORD to " \
                  "replace its credentials and end its sessions before it becomes a global admin."
          end

          user.replace_credentials!(password)
          user.update!(global_admin: true, global_admin_source: "admin_task")
          "#{email} is a global admin; its password was replaced and its sessions and tokens ended."
        else
          user.assign_attributes(global_admin: true, global_admin_source: "admin_task")
          if password
            user.assign_attributes(password: password, password_confirmation: password)
            user.end_mcp_access!
          end
          user.save!
          password ? "#{email} is a global admin; password updated and its MCP access ended." \
                   : "#{email} is a global admin. (No PASSWORD given, so the existing password stands.)"
        end
      end
      puts message
    else
      abort "Set PASSWORD to create a new user." if password.nil?
      User.create!(email: email, global_admin: true, global_admin_source: "admin_task", password: password, password_confirmation: password)
      puts "Created global admin #{email}."
    end
  end
end
