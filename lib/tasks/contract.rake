# frozen_string_literal: true

# The feedback exchange's Pact contract tests with Chip. They sit outside
# `bin/rails test` because each side runs alone: see
# docs/guidelines/feedback-exchange.md → Contract tests.
namespace :contract do
  consumer_test = "test/contract/chip_consumer_contract.rb"
  provider_test = "test/contract/chip_provider_contract.rb"

  desc "Run our consumer contract tests of Chip and refresh contract/pacts/growthos-chip.json"
  task :consumer do
    written = Rails.root.join("tmp/pact/consumer/growthos-chip.json")
    sh({ "PARALLEL_WORKERS" => "1" }, "bin/rails", "test", consumer_test)
    cp written, Rails.root.join("contract/pacts/growthos-chip.json")
  end

  desc "Verify our app as provider against Chip's pact of us: PACT_FILE=<a pact or a /contract response>"
  task :provider do
    pact_file = ENV["PACT_FILE"].presence or abort "Set PACT_FILE to Chip's pact of GrowthOS"
    sh({ "PARALLEL_WORKERS" => "1", "CHIP_PACT_FILE" => File.expand_path(pact_file) }, "bin/rails", "test", provider_test)
  end
end
