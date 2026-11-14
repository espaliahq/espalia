# frozen_string_literal: true

# Seals plan and scenario names stored in clear before [#209](https://github.com/espaliahq/espalia/issues/209). Output is
# tenant ids and counts only, never a name.
namespace :team_planning do
  namespace :names do
    desc "Count the records each tenant would seal. Changes nothing."
    task dry_run: :environment do
      Tenant.find_each do |tenant|
        counts = TeamPlanning::NameSealing.new(tenant).dry_run
        puts "[#{tenant.id}] would seal #{counts.values.sum}: #{counts.map { |type, n| "#{type.demodulize} #{n}" }.join(", ")}"
      end
    end

    desc "Seal every name stored in clear, one transaction per tenant, then rebuild plans and scenarios. Safe to rerun."
    task seal: :environment do
      Tenant.find_each do |tenant|
        counts = TeamPlanning::NameSealing.new(tenant).seal!
        puts "[#{tenant.id}] sealed #{counts.values.sum}: #{counts.map { |type, n| "#{type.demodulize} #{n}" }.join(", ")}"
      end
    end
  end
end
