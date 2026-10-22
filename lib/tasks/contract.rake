# frozen_string_literal: true

# The feedback exchange's Pact contract tests with Chip. They sit outside
# `bin/rails test` because each side runs alone: see
# docs/guidelines/feedback-exchange.md → Contract tests.
namespace :contract do
  consumer_test = "test/contract/chip_consumer_contract.rb"
  provider_test = "test/contract/chip_provider_contract.rb"
  peer_cache = "tmp/contract/chip.json"

  # GitHub turns these into annotations; elsewhere they are plain lines.
  annotate = ->(level, message) { puts ENV["GITHUB_ACTIONS"] == "true" ? "::#{level}::#{message}" : "#{level.capitalize}: #{message}" }

  resolve_peer = lambda do
    require_relative "feedback_exchange_contract"
    FeedbackExchangeContractTasks::PeerContract.new(
      url: ENV["FEEDBACK_EXCHANGE_PEER_CONTRACT_URL"], cache_file: Rails.root.join(peer_cache), fresh: ENV["FRESH"].present?
    ).resolve.tap { |result| result.warnings.each { |warning| annotate.call("warning", warning) } }
  rescue FeedbackExchangeContractTasks::PeerContract::Unavailable => e
    annotate.call("error", e.message)
    exit 1
  end

  desc "Run our consumer contract tests of Chip and refresh contract/pacts/growthos-chip.json"
  task :consumer do
    written = Rails.root.join("tmp/pact/consumer/growthos-chip.json")
    sh({ "PARALLEL_WORKERS" => "1" }, "bin/rails", "test", consumer_test)
    cp written, Rails.root.join("contract/pacts/growthos-chip.json")
  end

  desc "Fetch Chip's pact of us into #{peer_cache} (kept a day; FRESH=1 fetches anyway)"
  task :fetch_peer do
    puts resolve_peer.call.message
  end

  desc "Verify our app as provider against Chip's pact of us: PACT_FILE=<a pact or a /contract response>, " \
       "else Chip's deployed one from FEEDBACK_EXCHANGE_PEER_CONTRACT_URL through the cache"
  task :provider do
    pact_file = ENV["PACT_FILE"].presence
    unless pact_file
      result = resolve_peer.call
      puts result.message
      next annotate.call("warning", "Provider verification skipped: #{result.message}") unless result.pact_file

      pact_file = result.pact_file
    end
    sh({ "PARALLEL_WORKERS" => "1", "CHIP_PACT_FILE" => File.expand_path(pact_file) }, "bin/rails", "test", provider_test)
  end

  desc "Fail when contract/pacts/growthos-chip.json differs from our deployed /contract, " \
       "unless CONTRACT_CHANGE_LABELLED=true (the PR carries contract-change)"
  task :check_change do
    require_relative "feedback_exchange_contract"
    outcome, message = FeedbackExchangeContractTasks::ContractChange.check(
      committed: JSON.parse(Rails.root.join("contract/pacts/growthos-chip.json").read),
      url: ENV["FEEDBACK_EXCHANGE_OWN_CONTRACT_URL"].presence,
      labelled: ENV["CONTRACT_CHANGE_LABELLED"] == "true"
    )
    case outcome
    when :pass then puts message
    when :warn then annotate.call("warning", message)
    else
      annotate.call("error", message)
      exit 1
    end
  end
end
