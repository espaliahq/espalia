# frozen_string_literal: true

namespace :assessments do
  desc "Seed realistic population-wide assessment activity for calibration demos (development only)"
  task seed_calibration_activity: :environment do
    # Demo ratings across an entire org must never touch production —
    # hard abort rather than a silent skip so a misconfigured invocation
    # is loud.
    abort "assessments:seed_calibration_activity is development-only." unless Rails.env.development?

    slug = ENV["SEED_TENANT_SLUG"] || "nullisland"
    tenant = Tenant.find_by(slug: slug)
    unless tenant
      puts "No #{slug} tenant — skipping calibration activity seed."
      next
    end

    require_relative "calibration_activity_seed"
    CalibrationActivitySeed.new(tenant: tenant).call
  end
end
