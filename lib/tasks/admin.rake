# frozen_string_literal: true

namespace :admin do
  desc "Create or promote a global admin: bin/rails admin:create EMAIL=who@example.com PASSWORD=..."
  task create: :environment do
    email = ENV["EMAIL"].presence or abort "Set EMAIL (and PASSWORD for a new user)."
    password = ENV["PASSWORD"].presence

    user = User.find_by(email: email)
    if user
      user.update!(global_admin: true)
      puts "#{email} is a global admin."
    else
      abort "Set PASSWORD to create a new user." if password.nil?
      User.create!(email: email, global_admin: true, password: password, password_confirmation: password)
      puts "Created global admin #{email}."
    end
  end
end
