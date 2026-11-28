# frozen_string_literal: true

require "test_helper"

# The feedback modal's save stores all of its commands or none of them, and a
# save that stores nothing queues no job and broadcasts nothing.
class EvidenceSaveTransactionTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  setup do
    @tenant = create(:tenant)
    @author_user = create(:user, password: "password123")
    @peer_user = create(:user, password: "password123")
    @stranger_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @author = create(:person, tenant: @tenant, email: @author_user.email, name: "Author")
      @peer = create(:person, tenant: @tenant, email: @peer_user.email, name: "Peer")
      @stranger = create(:person, tenant: @tenant, email: @stranger_user.email, name: "Stranger")
      create(:tenant_user, tenant: @tenant, user: @author_user, person: @author, role: :member)
      create(:tenant_user, tenant: @tenant, user: @peer_user, person: @peer, role: :member)
      create(:tenant_user, tenant: @tenant, user: @stranger_user, person: @stranger, role: :member)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      @cap2 = create(:framework_capability, category_id: cat.category_id, name: "Systems Thinking")
      [ @cap, @cap2 ].each do |cap|
        create(:framework_capability_role_binding, capability_id: cap.capability_id, role_id: role.role_id, weight: 1.0)
        create(:framework_behavioural_expectation, capability_id: cap.capability_id, level_ordinal: 2, description: "x")
      end

      handler.assign_to_framework(@author.id, @framework_id, role.role_id, level.level_id)
      @item = SecureRandom.uuid_v7
      handler.record_evidence(@author.id, @framework_id, @item,
        capability_stable_id: @cap.stable_id, level_ordinal: 2, source: "peer", evidence_type: "peer_feedback",
        content: "Before", author_id: @peer.id, valence: "demonstrated")
    end
    @first = "#{@cap.stable_id}|2"
    @second = "#{@cap2.stable_id}|2"
  end

  context "an edit" do
    should "queue jobs and broadcast when it stores, so the checks below can see both" do
      sign_in @peer_user

      broadcasts = count_broadcasts { move_link_and_edit }

      assert_operator enqueued_jobs.size, :>, 0
      assert_operator broadcasts, :>, 0
      assert_equal "After", item_content
    end

    should "store nothing, queue nothing and broadcast nothing when its last command fails" do
      sign_in @peer_user

      assert_stores_nothing do
        fail_with(Operations::Assessments::RemoveEvidenceLink, PersonDevelopment::Aggregate::CommandError.new("Link is gone")) do
          move_link_and_edit
        end
      end
      assert_equal "Link is gone", flash[:alert]
    end

    should "store nothing when a later command is not allowed" do
      sign_in @peer_user

      assert_stores_nothing do
        fail_with(Operations::Assessments::RemoveEvidenceLink, Pundit::NotAuthorizedError.new) { move_link_and_edit }
      end
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end

    should "refuse a forgotten person's item even when only its text changes" do
      forget(@author)
      sign_in @peer_user

      assert_stores_nothing do
        patch evidence_item_path(@item), params: { return_to: "hub", evidence: {
          evidence_id: @item, desired_links: [ @first ], evidence_type: "peer_feedback", content: "After"
        } }
      end
      assert_equal "this person has been forgotten", flash[:alert]
    end

    should "give a caller who may not edit the item the ordinary refusal, even when its person is forgotten" do
      forget(@author)
      sign_in @stranger_user

      assert_stores_nothing { move_link_and_edit }
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  context "a response" do
    setup do
      @request_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        handler.request_evidence(@author.id, @framework_id, @request_id,
          requested_by_id: @author.id, requestee_person_id: @peer.id,
          capability_stable_id: @cap.stable_id, level_ordinal: 2, message: "Pairing notes?")
      end
    end

    should "store nothing, and leave the request open, when a link after the response fails" do
      sign_in @peer_user

      assert_stores_nothing do
        fail_with(Operations::Assessments::AddEvidenceLink, PersonDevelopment::Aggregate::CommandError.new("No such cell")) do
          respond_with_two_links
        end
      end
      assert_equal "No such cell", flash[:alert]
      assert_equal "pending", request_status
    end

    should "store nothing when its person is forgotten" do
      forget(@author)
      sign_in @peer_user

      assert_stores_nothing { respond_with_two_links }
      assert_equal "this person has been forgotten", flash[:alert]
      assert_equal "pending", request_status
    end

    should "give a caller who was not asked the ordinary refusal, even when its person is forgotten" do
      forget(@author)
      sign_in @stranger_user

      assert_stores_nothing { respond_with_two_links }
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  private

  def handler = PersonDevelopment::CommandHandler.new

  # The content edit, then a link added, then the old link removed.
  def move_link_and_edit
    patch evidence_item_path(@item), params: { return_to: "hub", evidence: {
      evidence_id: @item, desired_links: [ @second ], link_valences: { @second => "demonstrated" },
      evidence_type: "peer_feedback", content: "After"
    } }
  end

  # The response, then a second link.
  def respond_with_two_links
    post respond_evidence_request_path(@request_id), params: { return_to: "hub", evidence: {
      request_id: @request_id, primary_cell: @first, desired_links: [ @first, @second ],
      link_valences: { @first => "demonstrated", @second => "demonstrated" },
      evidence_type: "peer_feedback", content: "Great pairing."
    } }
  end

  def fail_with(operation, error, &)
    operation.stub(:call, ->(**) { raise error }, &)
  end

  # Gathers every observation before asserting, so a failure shows them all.
  def assert_stores_nothing(&)
    before = { events: stream_events.size, links: active_links, text: item_content }
    jobs = enqueued_jobs.size
    broadcasts = count_broadcasts(&)

    after = { events: stream_events.size, links: active_links, text: item_content }
    assert_equal before.merge(jobs: 0, broadcasts: 0),
                 after.merge(jobs: enqueued_jobs.size - jobs, broadcasts: broadcasts)
  end

  def count_broadcasts(&)
    count = 0
    ActionCable.server.stub(:broadcast, ->(*, **) { count += 1 }, &)
    count
  end

  def forget(person)
    ActsAsTenant.with_tenant(@tenant) do
      person.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current)
    end
  end

  def stream_events
    stream = EventStreamNaming.person_development_stream(@author.id, @framework_id, tenant: @tenant)
    Rails.configuration.event_store.read.stream(stream).to_a
  end

  def active_links
    ActsAsTenant.with_tenant(@tenant) do
      EvidenceLink.active.where(evidence_id: @item).pluck(:capability_stable_id, :level_ordinal).sort
    end
  end

  def item_content = ActsAsTenant.with_tenant(@tenant) { EvidenceItem.find(@item).content }

  def request_status = ActsAsTenant.with_tenant(@tenant) { EvidenceRequest.find(@request_id).status }
end
