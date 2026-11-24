# frozen_string_literal: true

namespace :write_ownership do
  desc "Fail if a WRITE_CATALOGUE=1 test run recorded a write config/write_ownership.yml doesn't allow"
  task check: :environment do
    require Rails.root.join("test/support/write_catalogue_report").to_s
    require Rails.root.join("test/support/write_ownership").to_s

    violations = WriteOwnership.load.violations(WriteCatalogueReport.load)
    if violations.any?
      violations.each { |v| warn "#{v[:table]}: #{v[:projection] ? "inside #{v[:projection]}, " : ''}#{v[:reason]}" }
      abort <<~MSG
        #{violations.size} write(s) config/write_ownership.yml doesn't allow.
        Name the file among the table's writers, with the reason, or move the write behind the table's owner.
        See docs/architecture/direct-writes.md.
      MSG
    end
    puts "Every recorded write matches config/write_ownership.yml."
  end
end
