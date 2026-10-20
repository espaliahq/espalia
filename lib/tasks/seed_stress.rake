# frozen_string_literal: true

namespace :dev do
  namespace :seed do
    desc "Seed the Stress Test Co tenant: long text, volume, every state, empty states, hard theme colours (#542)"
    task stress: :environment do
      abort "dev:seed:stress is development-only." unless Rails.env.development? || Rails.env.test?

      require_relative "stress_seed"
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      tenant = StressSeed.new.call
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      puts "Stress seed complete for #{tenant.name} in #{elapsed.round(1)}s."
      puts "  Admin:  #{StressSeed::ADMIN_EMAIL} / #{StressSeed::PASSWORD}"
      puts "  Member: #{StressSeed::MEMBER_EMAIL} / #{StressSeed::PASSWORD}"
    end
  end
end
