# frozen_string_literal: true

# Our consumer pact of the peer (GET /api/feedback_exchange/feedback/contract),
# protocol §5.5: what this build's puller was tested against, so the peer can
# verify its provider against exactly that.
#
# Unsigned, tenant-free and served whatever any tenant's exchange is set to, so
# it skips the signed-request concern. It holds only the contract tests'
# synthetic people and example hosts. There is no Pundit `authorize`: nothing
# here belongs to anyone.
class FeedbackExchange::ContractsController < ActionController::Base
  PACT = Rails.root.join("contract/pacts/growthos-chip.json")
  PROTOCOL = "v1"

  # GET /api/feedback_exchange/feedback/contract
  def show
    expires_in 5.minutes, public: true
    render json: self.class.body
  end

  # The response, built once per version of the file: fixed for a deploy, and
  # rewritten in development by `bin/rails contract:consumer`.
  #
  # @return [String]
  def self.body
    version = PACT.mtime
    return @body if @body && @body_version == version

    @body_version = version
    @body = { protocol: PROTOCOL, build: Rails.application.config.x.release_id, consumer_pact: JSON.parse(PACT.read) }.to_json
  end
end
