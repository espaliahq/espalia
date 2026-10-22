# frozen_string_literal: true

require "net/http"
require "json"
require "fileutils"

# The two network steps of the feedback exchange contract checks (see
# lib/tasks/contract.rake), kept out of the rake file so they can be tested.
module FeedbackExchangeContractTasks
  PROTOCOL = "v1"
  MAX_AGE = 24 * 60 * 60
  TIMEOUT = 20

  # What a fetch got back.
  Response = Data.define(:status, :body)

  # GETs a URL as JSON; nil status when it could not be reached.
  #
  # @param url [String]
  # @return [Response]
  def self.get(url)
    uri = URI(url)
    answer = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.get(uri.request_uri, "Accept" => "application/json")
    end
    Response.new(status: answer.code.to_i, body: answer.body.to_s)
  rescue StandardError => e
    Response.new(status: nil, body: "#{e.class}: #{e.message}")
  end

  # Interactions in a written pact that still carry a matcher's own key. pact-ffi
  # turns every matcher it is given into an example and a rule, so the key
  # survives only when a matcher was mangled before it got there (a Hash
  # flattened into pairs), which the peer then reads as the example itself.
  #
  # @param pact [Hash]
  # @return [Array<String>] their descriptions
  def self.unprocessed_matchers(pact)
    pact.fetch("interactions").select { |interaction| interaction.to_json.include?("pact:matcher:type") }.pluck("description")
  end

  # Chip's consumer pact of us, from its /contract, through a cache: a copy
  # younger than a day is used as it is, a failed fetch falls back to any copy
  # with a warning, and only a failure with no copy at all is an error. Until
  # Chip publishes (a 404 with no copy), or while no URL is configured, there is
  # nothing to verify, which callers report as neutral.
  class PeerContract
    # @!attribute pact_file [String, nil] the /contract response to verify, nil when there is nothing to verify
    Result = Data.define(:pact_file, :message, :warnings)

    class Unavailable < StandardError; end

    # @param url [String, nil] Chip's /contract
    # @param cache_file [String, Pathname]
    # @param fresh [Boolean] fetch even when the copy is young
    # @param fetch [#call] url -> Response
    # @param now [Time]
    def initialize(url:, cache_file:, fresh: false, fetch: FeedbackExchangeContractTasks.method(:get), now: Time.now)
      @url = url.to_s.strip.presence
      @cache_file = Pathname(cache_file)
      @fresh = fresh
      @fetch = fetch
      @now = now
    end

    # @return [Result]
    # @raise [Unavailable] when the fetch failed and there is no copy to fall
    #   back on, or Chip answered with something other than its v1 pact of us
    def resolve
      return Result.new(nil, "No peer contract URL is set (FEEDBACK_EXCHANGE_PEER_CONTRACT_URL); nothing to verify.", []) unless @url
      return cached("the copy is under a day old") if cache && !@fresh && young?

      response = @fetch.call(@url)
      if response.status == 404 && cache.nil?
        return Result.new(nil, "Chip has not published its contract yet (#{@url} answered 404); nothing to verify.", [])
      end
      return fall_back("#{@url} answered #{response.status || response.body}") unless response.status == 200

      # An answer that is the wrong contract is a change on Chip's side to
      # look at, never a reason to keep verifying against an old copy.
      store(parse(response.body))
      Result.new(@cache_file.to_s, "Fetched Chip's contract from #{@url}.", [])
    end

    private

    # The copy, when it came from this URL and says when; anything else is no copy.
    def cache
      return @cache if defined?(@cache)

      copy = @cache_file.exist? ? JSON.parse(@cache_file.read) : nil
      @cache = copy if copy.is_a?(Hash) && copy["source_url"] == @url && Time.iso8601(copy["fetched_at"].to_s)
    rescue JSON::ParserError, ArgumentError
      @cache = nil
    end

    def young? = @now - Time.iso8601(cache.fetch("fetched_at")) < MAX_AGE

    def cached(reason) = Result.new(@cache_file.to_s, "Using the cached copy of Chip's contract fetched #{cache['fetched_at']} (#{reason}).", [])

    def fall_back(reason)
      raise Unavailable, "Chip's contract is unavailable and there is no cached copy: #{reason}" if cache.nil?

      Result.new(@cache_file.to_s, "Using the cached copy of Chip's contract fetched #{cache['fetched_at']}.",
                 [ "Could not refresh Chip's contract (#{reason}); verifying against the copy fetched #{cache['fetched_at']}." ])
    end

    def parse(body)
      contract = begin
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
      raise Unavailable, "#{@url} is not a /contract response" unless contract.is_a?(Hash) && contract["consumer_pact"].is_a?(Hash)
      raise Unavailable, "#{@url} speaks protocol #{contract['protocol'].inspect}, not #{PROTOCOL}" unless contract["protocol"] == PROTOCOL

      pact = contract["consumer_pact"]
      unless pact.dig("consumer", "name") == "chip" && pact.dig("provider", "name") == "growthos"
        raise Unavailable, "#{@url} serves a pact from #{pact.dig('consumer', 'name')} to #{pact.dig('provider', 'name')}, not chip to growthos"
      end

      contract
    end

    def store(contract)
      FileUtils.mkdir_p(@cache_file.dirname)
      @cache_file.write(JSON.pretty_generate(contract.merge("fetched_at" => @now.utc.iso8601, "source_url" => @url)))
    end
  end

  # Whether a branch changes our consumer pact compared with the one our
  # deployment serves. A change alters what Chip must honour, so it needs the
  # `contract-change` label, which says Chip's harness passed against the new
  # file and the PR links that run.
  module ContractChange
    module_function

    # @param committed [Hash] the branch's contract/pacts/growthos-chip.json
    # @param url [String, nil] our deployed /contract
    # @param labelled [Boolean]
    # @param fetch [#call] url -> Response
    # @return [Array(Symbol, String)] :pass, :warn or :fail, and why
    def check(committed:, url:, labelled:, fetch: FeedbackExchangeContractTasks.method(:get))
      return [ :warn, "No deployed contract URL is set (FEEDBACK_EXCHANGE_OWN_CONTRACT_URL); nothing to compare with." ] if url.blank?

      response = fetch.call(url)
      return [ :warn, "Our /contract is not deployed yet (#{url} answered 404); nothing to compare with." ] if response.status == 404
      return [ :fail, "#{url} answered #{response.status || response.body}. Re-run the check." ] unless response.status == 200

      deployed = JSON.parse(response.body)["consumer_pact"]
      return [ :pass, "Our consumer pact is unchanged from the deployed one." ] if normalize(deployed) == normalize(committed)
      return [ :pass, "Our consumer pact changes, and the PR carries contract-change: link Chip's passing run against it." ] if labelled

      [ :fail, "This PR changes contract/pacts/growthos-chip.json, so it changes what Chip must honour. Run Chip's harness " \
               "against the new file (npm run contract:provider -- --pact-file <path> in Chip's repo), link the passing " \
               "run in the PR and add the contract-change label." ]
    end

    # The contract without the Pact library's versions: participants, spec
    # version and interactions, in any order.
    def normalize(pact)
      pact ||= {}
      {
        "consumer" => pact["consumer"], "provider" => pact["provider"],
        "spec" => pact.dig("metadata", "pactSpecification"),
        "interactions" => Array(pact["interactions"]).map { |interaction| deep_sort(interaction).to_json }.sort
      }
    end

    def deep_sort(value)
      case value
      when Hash then value.sort.to_h.transform_values { |v| deep_sort(v) }
      when Array then value.map { |v| deep_sort(v) }
      else value
      end
    end
  end
end
