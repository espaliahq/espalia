# frozen_string_literal: true

require "test_helper"

class Evidence::ConversationReadsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    @other_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      @me = create(:person, tenant: @tenant, email: @user.email)
      @peer = create(:person, tenant: @tenant)
      @item = create(:evidence_item, tenant: @tenant, author: @peer, person_id: @me.id)
      @request = create(:evidence_request, tenant: @tenant, requester: @peer, requestee: @me, person_id: @peer.id)
    end
  end

  def notify(type, recipient: @user, record: nil, **params)
    event = Noticed::Event.create!(type: type, record: record, params: { tenant_id: @tenant.id, **params })
    Noticed::Notification.create!(type: "#{type}::Notification", event: event, recipient: recipient)
  end

  def conversation_message(kind, request: nil, item: nil)
    Evidence::Conversations::Message.new(kind: kind, at: Time.current, request: request, item: item)
  end

  should "read an item notification by its record and a request notification by its params" do
    notify("FeedbackReceivedNotifier", record: @item)
    notify("EvidenceRequestedNotifier", request_id: @request.id)

    reads = Evidence::ConversationReads.new(@user)
    assert reads.unread?(conversation_message(:feedback, item: @item))
    assert reads.unread?(conversation_message(:request, request: @request))
  end

  should "count a reply unread through the requester's answered notification" do
    notify("EvidenceRequestRespondedNotifier", request_id: @request.id)

    assert Evidence::ConversationReads.new(@user).unread?(conversation_message(:reply, request: @request, item: @item))
  end

  should "treat a message nobody was notified about as read" do
    assert_not Evidence::ConversationReads.new(@user).unread?(conversation_message(:feedback, item: @item))
  end

  should "ignore someone else's notifications and ones already read" do
    notify("FeedbackReceivedNotifier", recipient: @other_user, record: @item)
    notify("EvidenceRequestedNotifier", request_id: @request.id).update!(read_at: 1.hour.ago)

    reads = Evidence::ConversationReads.new(@user)
    assert_not reads.unread?(conversation_message(:feedback, item: @item))
    assert_not reads.unread?(conversation_message(:request, request: @request))
  end

  should "mark only the given messages' notifications read, stamping seen_at too" do
    mine = notify("FeedbackReceivedNotifier", record: @item)
    other = notify("EvidenceRequestedNotifier", request_id: @request.id)

    reads = Evidence::ConversationReads.new(@user)
    assert_equal 1, reads.mark_read!([ conversation_message(:feedback, item: @item) ])

    assert mine.reload.read_at
    assert mine.seen_at
    assert_nil other.reload.read_at
    assert_not reads.unread?(conversation_message(:feedback, item: @item))
    assert reads.unread?(conversation_message(:request, request: @request))
  end
end
