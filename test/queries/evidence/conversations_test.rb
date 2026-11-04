# frozen_string_literal: true

require "test_helper"

class Evidence::ConversationsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @framework_id = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      @maya = create(:person, tenant: @tenant, name: "Maya Manager")
      @alex = create(:person, tenant: @tenant, name: "Alex Report", manager: @maya)
      @jordan = create(:person, tenant: @tenant, name: "Jordan Peer")
      @priya = create(:person, tenant: @tenant, name: "Priya Peer")
      [ @maya, @alex, @jordan, @priya ].each do |person|
        create(:person_framework_assignment, tenant: @tenant, person_id: person.id, framework_id: @framework_id)
      end
    end
  end

  def conversations(viewer, group: "person", scope: "team")
    ActsAsTenant.with_tenant(@tenant) { Evidence::Conversations.new(viewer, group: group, scope: scope).tap(&:all) }
  end

  def item(author:, about:, at: 1.day.ago, **attrs)
    ActsAsTenant.with_tenant(@tenant) do
      create(:evidence_item, tenant: @tenant, author: author, person_id: about.id, framework_id: @framework_id,
                             source: author == about ? "self" : "peer", recorded_at: at, **attrs)
    end
  end

  def unplaced(author:, about:, at: 1.day.ago)
    item(author: author, about: about, at: at, capability_stable_id: nil, level_ordinal: nil, with_link: false)
  end

  def request(from:, to:, about:, at: 3.days.ago, **attrs)
    ActsAsTenant.with_tenant(@tenant) do
      create(:evidence_request, tenant: @tenant, requester: from, requestee: to, person_id: about.id,
                                framework_id: @framework_id, requested_at: at, **attrs)
    end
  end

  def thread_ids(convos) = convos.all.map(&:person_id)
  def message_kinds(convo) = convo.messages.map(&:kind)

  context "which conversation a message belongs to" do
    should "put a request with the other party, on both sides" do
      ask = request(from: @maya, to: @jordan, about: @alex)

      assert_equal [ ask.id ], conversations(@maya).find(@jordan.id).messages.map { |m| m.request.id }
      assert_equal [ ask.id ], conversations(@jordan).find(@maya.id).messages.map { |m| m.request.id }
    end

    should "keep a reply with its request, even when its writer is talking about someone else" do
      answer = item(author: @jordan, about: @alex, at: 1.hour.ago)
      ask = request(from: @maya, to: @jordan, about: @alex, status: "responded", evidence_id: answer.id)

      jordan = conversations(@jordan)
      assert_equal [ @maya.id ], thread_ids(jordan)
      assert_equal %i[request reply], message_kinds(jordan.find(@maya.id))
      assert_equal ask.id, jordan.find(@maya.id).messages.last.request.id
    end

    should "file what the viewer wrote with the person it is about, and notes to self with the viewer" do
      item(author: @maya, about: @priya)
      item(author: @maya, about: @maya)

      assert_equal [ @maya.id, @priya.id ].sort, thread_ids(conversations(@maya)).sort
    end

    should "file anyone else's feedback with its author" do
      item(author: @priya, about: @maya)

      assert_equal [ @priya.id ], thread_ids(conversations(@maya))
    end

    should "show the person a request was about the answer, with its author, when they can't see the ask" do
      answer = item(author: @jordan, about: @alex)
      request(from: @maya, to: @jordan, about: @alex, status: "responded", evidence_id: answer.id)

      alex = conversations(@alex)
      assert_equal [ @jordan.id ], thread_ids(alex)
      assert_equal %i[feedback], message_kinds(alex.find(@jordan.id))
    end

    should "put a declined request's answer after the ask" do
      request(from: @maya, to: @jordan, about: @maya, status: "declined", declined_at: 1.day.ago)

      assert_equal %i[request declined], message_kinds(conversations(@maya).find(@jordan.id))
    end
  end

  context "what the viewer may see" do
    should "leave out feedback between other people about someone outside their reports" do
      item(author: @jordan, about: @priya)

      assert_empty conversations(@maya).all
    end

    should "include feedback about a report from someone else" do
      item(author: @priya, about: @alex)

      assert_equal [ @priya.id ], thread_ids(conversations(@maya))
    end

    should "leave out a report's own notes unless they wait on a placement decision" do
      note = item(author: @alex, about: @alex)
      assert_empty conversations(@maya).all

      ActsAsTenant.with_tenant(@tenant) { create(:evidence_placement_suggestion, tenant: @tenant, item: note) }
      assert_equal [ @alex.id ], thread_ids(conversations(@maya))
    end

    should "leave out withdrawn feedback" do
      item(author: @priya, about: @maya, link_status: "withdrawn")

      assert_empty conversations(@maya).all
    end
  end

  context "the report group" do
    should "key everything about a report by the report, and leave out the rest" do
      item(author: @priya, about: @alex)
      item(author: @maya, about: @alex)
      request(from: @maya, to: @jordan, about: @alex)
      item(author: @jordan, about: @maya)

      reports = conversations(@maya, group: "report")
      assert_equal [ @alex.id ], thread_ids(reports)
      assert_equal 3, reports.find(@alex.id).messages.size
    end

    should "be the default only for someone with reports in view" do
      assert_equal "report", conversations(@maya).default_group
      assert_equal "report", conversations(@maya, scope: "mine").default_group
      assert_equal "person", conversations(@jordan).default_group
    end
  end

  context "the team and org scopes" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @sky = create(:person, tenant: @tenant, name: "Sky Skiplevel", manager: @alex)
        create(:person_framework_assignment, tenant: @tenant, person_id: @sky.id, framework_id: @framework_id)
      end
    end

    should "list only direct reports in the team scope, and the subtree in the org scope" do
      item(author: @jordan, about: @alex)
      item(author: @priya, about: @sky)

      assert_equal [ @alex.id ], thread_ids(conversations(@maya, group: "report"))
      assert_equal [ @jordan.id ], thread_ids(conversations(@maya))
      assert_equal [ @alex.id, @sky.id ].sort, thread_ids(conversations(@maya, group: "report", scope: "org")).sort
      assert_equal [ @jordan.id, @priya.id ].sort, thread_ids(conversations(@maya, scope: "org")).sort
    end

    should "keep the viewer's own feedback and requests in both scopes" do
      mine = item(author: @maya, about: @sky)
      ask = request(from: @maya, to: @priya, about: @sky)

      team = conversations(@maya)
      assert_equal [ mine.id ], team.find(@sky.id).messages.map { |m| m.item.id }
      assert_equal [ ask.id ], team.find(@priya.id).messages.map { |m| m.request.id }
    end

    should "say whether the org reaches beyond the team" do
      assert conversations(@maya).beyond_team?
      assert_not conversations(@alex).beyond_team?
    end
  end

  context "My feedback and About me" do
    should "gather everything about the viewer into one About me thread, and nothing else" do
      from_jordan = item(author: @jordan, about: @maya, at: 3.days.ago)
      note = item(author: @maya, about: @maya, at: 2.days.ago)
      answer = item(author: @priya, about: @maya, at: 1.hour.ago)
      asked = request(from: @maya, to: @priya, about: @maya, at: 1.day.ago, status: "responded", evidence_id: answer.id)
      item(author: @maya, about: @jordan)
      request(from: @priya, to: @maya, about: @priya)
      item(author: @jordan, about: @alex)

      about_me = conversations(@maya, group: "report", scope: "mine")
      assert about_me.about_me?
      assert_equal [ @maya.id ], thread_ids(about_me)
      thread = about_me.find(@maya.id)
      assert_equal [ from_jordan.id, note.id, answer.id ], thread.messages.filter_map { |m| m.item&.id }
      assert_equal [ asked.id ], thread.messages.select { |m| m.kind == :request }.map { |m| m.request.id }
    end

    should "leave feedback about reports out of the viewer's own conversations" do
      item(author: @jordan, about: @alex)
      item(author: @priya, about: @maya)

      assert_equal [ @priya.id ], thread_ids(conversations(@maya, scope: "mine"))
    end

    should "make the report group About me for someone nobody reports to, in any scope" do
      mine = item(author: @maya, about: @jordan)

      jordan = conversations(@jordan, group: "report")
      assert jordan.about_me?
      assert_not jordan.manager?
      assert_equal [ mine.id ], jordan.find(@jordan.id).messages.map { |m| m.item.id }
    end

    should "owe placing feedback about the viewer in My feedback, never a report's" do
      about_me = unplaced(author: @jordan, about: @maya)
      unplaced(author: @jordan, about: @alex)

      mine = conversations(@maya, scope: "mine")
      assert mine.find(@jordan.id).owes
      assert_equal [ about_me.id ], mine.find(@jordan.id).messages.map { |m| m.item.id }
    end
  end

  context "ordering" do
    should "list the most recently active conversation first, each oldest to newest" do
      item(author: @priya, about: @maya, at: 5.days.ago)
      item(author: @jordan, about: @maya, at: 2.days.ago)
      item(author: @priya, about: @maya, at: 1.day.ago)

      convos = conversations(@maya)
      assert_equal [ @priya.id, @jordan.id ], thread_ids(convos)
      times = convos.find(@priya.id).messages.map(&:at)
      assert_equal times.sort, times
    end

    should "place a reply at the time it was sent, not beside its request" do
      answer = item(author: @jordan, about: @maya, at: 1.hour.ago)
      request(from: @maya, to: @jordan, about: @maya, at: 10.days.ago, status: "responded", evidence_id: answer.id)
      item(author: @jordan, about: @maya, at: 5.days.ago)

      assert_equal %i[request feedback reply], message_kinds(conversations(@maya).find(@jordan.id))
    end
  end

  context "what is owed" do
    should "owe a pending request sent to the viewer, not one they sent" do
      request(from: @jordan, to: @maya, about: @jordan)
      request(from: @maya, to: @priya, about: @maya)

      convos = conversations(@maya)
      assert convos.find(@jordan.id).owes
      assert_not convos.find(@priya.id).owes
      assert convos.find(@priya.id).waiting
    end

    should "owe placing feedback about the viewer or a report, never feedback they wrote" do
      unplaced(author: @priya, about: @alex)
      unplaced(author: @maya, about: @jordan)

      convos = conversations(@maya)
      assert convos.find(@priya.id).owes
      assert_not convos.find(@jordan.id).owes
    end
  end

  should "find the conversation holding a request or an item" do
    ask = request(from: @maya, to: @jordan, about: @maya)
    note = item(author: @priya, about: @maya)

    convos = conversations(@maya)
    assert_equal @jordan.id, convos.containing(request_id: ask.id).person_id
    assert_equal @priya.id, convos.containing(item_id: note.id).person_id
    assert_nil convos.containing(item_id: SecureRandom.uuid_v7)
  end
end
