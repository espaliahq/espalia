# frozen_string_literal: true

# What both sides of the feedback exchange contract tests agree on (Chip's
# contract/README.md): the shared test secret and the frozen clock every
# request in either pact is signed with, so the signatures are in the pacts.
module FeedbackExchangeContract
  PACT_SECRET = "pact-test-secret-0123456789abcdef0123456789abcdef"
  PACT_KEY_ID = "e6bf4220007d6a9a"
  # 2026-10-21T00:00:00Z
  PACT_TIMESTAMP = "1792540800"

  COMMITTED_PACT = FeedbackExchange::ContractsController::PACT
  # The consumer tests merge into this; `bin/rails contract:consumer` copies it
  # over the committed pact once they pass, so running one test never does.
  CONSUMER_PACT_DIR = Rails.root.join("tmp/pact/consumer")
end
