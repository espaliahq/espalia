# frozen_string_literal: true

require "test_helper"

class FeedbackExchange::FeedControllerTest < ActionDispatch::IntegrationTest
  include FeedbackExchangeProducerHelpers

  setup do
    setup_exchange_tenant
    @author = create_person("Priya@Example.com", hris_source: "hibob", external_id: "3141")
    @recipient = create_person("sam@example.com", status: "inactive")
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context "the record" do
    should "carry every field of protocol section 4" do
      cycle = create(:assessment_cycle, tenant: @tenant, name: "Q4 2026")
      framework_id = SecureRandom.uuid_v7
      assignment = create(:person_framework_assignment, tenant: @tenant, person_id: @recipient.id, framework_id: framework_id)
      item = create_item(author: @author, recipient: @recipient, framework_id: framework_id, cycle_id: cycle.cycle_id,
                         title: "Incident call", content: "Calm under pressure.", evidence_type: "observation")
      requester = create_person("lee@example.com")
      request = create(:evidence_request, tenant: @tenant, requester: requester, requestee: @author,
                                          person_id: @recipient.id, evidence_id: item.id, status: "responded",
                                          message: "How did the incident go?", responded_at: Time.current)

      signed_get

      assert_response :success
      record = response.parsed_body["items"].sole
      assert_equal item.id, record["id"]
      assert_equal "growthos", record["origin"]
      assert_equal "active", record["status"]
      assert_equal item.recorded_at.utc.iso8601(6), record["given_at"]
      assert_equal item.reload.updated_at.utc.iso8601(6), record["updated_at"]
      assert_equal "observation", record["kind"]
      assert_equal "**Incident call**\n\nCalm under pressure.", record["text"]
      assert_equal "markdown", record["text_format"]
      assert_equal({ "email" => "priya@example.com", "display_name" => "Priya", "active" => true,
                     "external_ids" => { "hibob" => "3141" } }, record["author"])
      assert_equal({ "email" => "sam@example.com", "display_name" => "Sam", "active" => false,
                     "external_ids" => {} }, record["recipient"])
      assert_equal({ "id" => request.id, "context" => "How did the incident go?",
                     "requested_by" => { "email" => "lee@example.com", "display_name" => "Lee",
                                         "active" => true, "external_ids" => {} } }, record["request"])
      assert_equal({ "id" => cycle.cycle_id, "name" => "Q4 2026" }, record["period"])
      assert_equal %w[recipient management_line hr], record["audience"]
      assert_equal %w[recipient manager], record["notified"]
      assert_equal "http://example.com/assessments/#{assignment.id}?capability=#{item.capability_stable_id}&level_ordinal=3",
                   record["source_url"]
      assert_nil record["external_reference"]
    end

    should "send no internal person ids" do
      create_item(author: @author, recipient: @recipient)

      signed_get

      [ @author.id, @recipient.id ].each { |id| assert_not_includes response.body, id }
    end

    should "send null request and period for unprompted feedback outside a cycle" do
      create_item(author: @author, recipient: @recipient)

      signed_get

      record = response.parsed_body["items"].sole
      assert_nil record["request"]
      assert_nil record["period"]
    end

    should "link an unplaced item to the feedback hub" do
      item = create_item(author: @author, recipient: @recipient, capability_stable_id: nil, level_ordinal: nil,
                         with_link: false, recorded_unplaced: true)

      signed_get

      assert_equal "http://example.com/evidence#evidence-item-#{item.id}", response.parsed_body["items"].sole["source_url"]
    end

    should "send a withdrawn item with its status and no text" do
      item = create_item(author: @author, recipient: @recipient, link_status: "withdrawn", withdrawn_at: Time.current,
                         title: "Incident call", content: "Calm under pressure.")

      signed_get

      assert_equal [ item.id ], feed_ids
      record = response.parsed_body["items"].sole
      assert_equal "withdrawn", record["status"]
      assert_equal "", record["text"]
      assert_not_includes response.body, "Calm under pressure."
      assert_not_includes response.body, "Incident call"
    end
  end

  context "filtering" do
    should "leave out a person's own self-assessment evidence" do
      create_item(author: @author, recipient: @author, source: "self", evidence_type: "impact")
      peer = create_item(author: @author, recipient: @recipient)

      signed_get

      assert_equal [ peer.id ], feed_ids
    end

    should "leave out what the asking consumer itself sent" do
      imported = create_item(author: @author, recipient: @recipient, recorded_via: "feedback_exchange",
                             external_reference: { system: "chip", external_id: "c-1" })
      by_reference = create_item(author: @author, recipient: @recipient, external_reference: { system: "chip", external_id: "c-2" })
      other = create_item(author: @author, recipient: @recipient, external_reference: { system: "github", url: "https://github.com/o/r/pull/1" })

      signed_get

      assert_equal [ other.id ], feed_ids
      assert_not_includes feed_ids, imported.id
      assert_not_includes feed_ids, by_reference.id
    end

    should "match the consumer without regard to case" do
      create_item(author: @author, recipient: @recipient, external_reference: { system: "chip", external_id: "c-2" })

      signed_get(consumer: "Chip")

      assert_empty feed_ids
    end

    should "leave out what the consumer sent even when the stored system is mixed case" do
      create_item(author: @author, recipient: @recipient, external_reference: { system: "Chip", external_id: "c-3" })

      signed_get(consumer: "chip")

      assert_empty feed_ids
    end

    should "leave out items nobody wrote" do
      %w[hris system feedback_exchange].each { |via| create_item(author: @author, recipient: @recipient, recorded_via: via) }
      kept = %w[web mcp slack].map { |via| create_item(author: @author, recipient: @recipient, recorded_via: via) }
      history = create_item(author: @author, recipient: @recipient, recorded_via: nil)

      signed_get

      assert_equal (kept + [ history ]).map(&:id).sort, feed_ids.sort
    end

    should "send only the kinds the tenant exports" do
      @tenant.update_feedback_exchange!(settings: { export_kinds: %w[observation] })
      kept = create_item(author: @author, recipient: @recipient, evidence_type: "observation")
      create_item(author: @author, recipient: @recipient, evidence_type: "peer_feedback")
      create_item(author: @author, recipient: @recipient, evidence_type: "code_review")

      signed_get

      assert_equal [ kept.id ], feed_ids
    end

    should "leave out an acknowledged import but keep an acknowledged original" do
      original = create_item(author: @author, recipient: @recipient)
      create(:feedback_exchange_ack, tenant: @tenant, evidence_id: original.id, consumer: "chip")
      imported = create_item(author: @author, recipient: @recipient, external_reference: { system: "lattice", external_id: "l-1" })
      create(:feedback_exchange_ack, tenant: @tenant, evidence_id: imported.id, consumer: "chip")
      unacked_import = create_item(author: @author, recipient: @recipient, external_reference: { system: "lattice", external_id: "l-2" })

      signed_get

      assert_equal [ original.id, unacked_import.id ].sort, feed_ids.sort
    end

    should "not serve another tenant's feedback" do
      other = create(:tenant)
      ActsAsTenant.with_tenant(other) do
        person = create(:person, tenant: other)
        create(:evidence_item, tenant: other, author: person, person_id: person.id, source: "peer", evidence_type: "peer_feedback")
      end
      mine = create_item(author: @author, recipient: @recipient)

      signed_get

      assert_equal [ mine.id ], feed_ids
    end
  end

  context "paging" do
    setup do
      base = Time.utc(2026, 10, 1, 12)
      @items = Array.new(5) do |index|
        create_item(author: @author, recipient: @recipient, updated_at: base + index.minutes)
      end
    end

    should "return the first page with a cursor and has_more" do
      signed_get("#{FEED_PATH}?limit=2")

      assert_equal @items.first(2).map(&:id), feed_ids
      assert_equal true, response.parsed_body["has_more"]
      assert_predicate response.parsed_body["next_cursor"], :present?
    end

    should "walk the feed page by page with no gaps or repeats" do
      seen = []
      path = "#{FEED_PATH}?limit=2"
      loop do
        signed_get(path)
        seen.concat(feed_ids)
        break unless response.parsed_body["has_more"]

        path = "#{FEED_PATH}?limit=2&since=#{response.parsed_body['next_cursor']}"
        travel 1.second # a new signature each page
      end

      assert_equal @items.map(&:id), seen
    end

    should "not repeat or lose rows that share an updated_at across a page boundary" do
      tied_at = Time.utc(2026, 11, 1)
      tied = Array.new(3) { create_item(author: @author, recipient: @recipient, updated_at: tied_at) }.sort_by(&:id)

      signed_get("#{FEED_PATH}?limit=4")
      cursor = response.parsed_body["next_cursor"]
      first = feed_ids
      travel 1.second
      signed_get("#{FEED_PATH}?limit=4&since=#{cursor}")

      assert_equal (@items.map(&:id) + tied.map(&:id)), first + feed_ids
    end

    should "return only newer rows for a repeat with the returned cursor" do
      signed_get
      cursor = response.parsed_body["next_cursor"]
      assert_equal false, response.parsed_body["has_more"]
      travel 1.second

      signed_get("#{FEED_PATH}?since=#{cursor}")
      assert_empty feed_ids
      assert_equal cursor, response.parsed_body["next_cursor"]
      travel 1.second

      edited = @items.second
      edited.update!(content: "Edited later")
      added = create_item(author: @author, recipient: @recipient)
      signed_get("#{FEED_PATH}?since=#{cursor}")

      assert_equal [ edited.id, added.id ], feed_ids
      assert_equal "Edited later", response.parsed_body["items"].first["text"]
    end

    should "stay stable when rows are inserted behind the cursor" do
      signed_get("#{FEED_PATH}?limit=2")
      cursor = response.parsed_body["next_cursor"]
      late = create_item(author: @author, recipient: @recipient)
      travel 1.second

      signed_get("#{FEED_PATH}?limit=10&since=#{cursor}")

      assert_equal @items.drop(2).map(&:id) + [ late.id ], feed_ids
    end

    should "cap the page size at 200" do
      feed = FeedbackExchange::Feed.new(consumer: "chip", config: @tenant.feedback_exchange_config, limit: 5000)

      assert_equal 5, feed.page.items.size
      assert_equal 200, feed.instance_variable_get(:@limit)
    end

    should "refuse a limit that is not a positive integer" do
      [ "0", "-3", "many", "2.5" ].each do |limit|
        travel 1.second
        signed_get("#{FEED_PATH}?limit=#{limit}")
        assert_response :bad_request, "limit=#{limit}"
      end
    end

    should "refuse a cursor that is not ours" do
      [ "garbage", Base64.urlsafe_encode64("[1,2]"), Base64.urlsafe_encode64([ "yesterday", SecureRandom.uuid ].to_json),
        Base64.urlsafe_encode64([ Time.current.iso8601, "not-a-uuid" ].to_json) ].each do |cursor|
        travel 1.second
        signed_get("#{FEED_PATH}?since=#{cursor}")
        assert_response :bad_request, "since=#{cursor}"
      end
    end
  end

  context "query cost" do
    should "cost the same for a page of one as a page of many" do
      cycle = create(:assessment_cycle, tenant: @tenant)
      build_item = lambda do |index|
        item = create_item(author: create_person("a#{index}@example.com"), recipient: create_person("r#{index}@example.com"),
                           cycle_id: cycle.cycle_id)
        create(:evidence_request, tenant: @tenant, requester: create_person("q#{index}@example.com"), requestee: @author,
                                  person_id: item.person_id, evidence_id: item.id, status: "responded", responded_at: Time.current)
        create(:person_framework_assignment, tenant: @tenant, person_id: item.person_id, framework_id: item.framework_id)
      end

      build_item.call(0)
      one = count_queries { signed_get }
      assert_equal 1, response.parsed_body["items"].size

      5.times { |index| build_item.call(index + 1) }
      travel 1.second
      many = count_queries { signed_get }

      assert_equal 6, response.parsed_body["items"].size
      assert_equal one, many
    end
  end

  context "access" do
    should "refuse a consumer header that names another system than the tenant's peer" do
      signed_get(consumer: "other")

      assert_response :bad_request
    end

    should "refuse an unsigned request" do
      get FEED_PATH
      assert_response :unauthorized
    end

    should "refuse a signature made for another path" do
      Rails.stub(:cache, @cache) { get "#{FEED_PATH}?limit=1", headers: signed_headers(path: FEED_PATH) }
      assert_response :unauthorized
    end

    should "refuse a replay" do
      headers = signed_headers
      Rails.stub(:cache, @cache) { get FEED_PATH, headers: headers }
      assert_response :success

      Rails.stub(:cache, @cache) { get FEED_PATH, headers: headers }
      assert_response :unauthorized
    end

    should "answer 404 while the exchange is disabled" do
      @tenant.update!(feedback_exchange_config: @tenant.feedback_exchange_config.tap { |config| config.enabled = false })

      signed_get

      assert_response :not_found
    end
  end

  private

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:sql].match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end
end
