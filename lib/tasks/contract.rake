# frozen_string_literal: true

# The feedback exchange's Pact contract tests with Chip. They sit outside
# `bin/rails test` because each side runs alone: see
# docs/guidelines/feedback-exchange.md → Contract tests.
namespace :contract do
  consumer_test = "test/contract/chip_consumer_contract.rb"

  desc "Run our consumer contract tests of Chip and refresh contract/pacts/growthos-chip.json"
  task :consumer do
    written = Rails.root.join("tmp/pact/consumer/growthos-chip.json")
    sh({ "PARALLEL_WORKERS" => "1" }, "bin/rails", "test", consumer_test)
    cp written, Rails.root.join("contract/pacts/growthos-chip.json")
  end
end
