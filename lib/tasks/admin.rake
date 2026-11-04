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
      user.assign_attributes(global_admin: true)
      user.assign_attributes(password: password, password_confirmation: password) if password
      user.save!
      puts password ? "#{email} is a global admin; password updated." \
                    : "#{email} is a global admin. (No PASSWORD given, so the existing password stands.)"
    else
      abort "Set PASSWORD to create a new user." if password.nil?
      User.create!(email: email, global_admin: true, password: password, password_confirmation: password)
      puts "Created global admin #{email}."
    end
  end
end
