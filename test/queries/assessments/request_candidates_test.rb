# frozen_string_literal: true

require "test_helper"

class Assessments::RequestCandidatesTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7
    @cap = SecureRandom.uuid_v7

    @manager  = create(:person, tenant: @tenant, name: "Morgan Manager", email: "morgan@example.com")
    @assessee = create(:person, tenant: @tenant, name: "Alex Assessee", email: "alex@example.com", manager: @manager)
    @peer     = create(:person, tenant: @tenant, name: "Priya Peer", email: "priya@example.com", manager: @manager)
    @report   = create(:person, tenant: @tenant, name: "Riley Report", email: "riley@example.com", manager: @assessee)
    @stranger = create(:person, tenant: @tenant, name: "Sam Stranger", email: "sam@example.com")

    @assignment = create(:person_framework_assignment, tenant: @tenant,
      person_id: @assessee.id, framework_id: @framework_id)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def query(requester: @assessee)
    Assessments::RequestCandidates.new(
      assignment: @assignment, requester_person_id: requester.id,
      capability_stable_id: @cap, level_ordinal: 3
    )
  end

  def pending_request_from(person)
    EvidenceRequest.create!(
      id: SecureRandom.uuid_v7, tenant: @tenant, person_id: @assessee.id, framework_id: @framework_id,
      requested_by_id: @manager.id, requestee_person_id: person.id,
      capability_stable_id: @cap, level_ordinal: 3, status: "pending", requested_at: Time.current
    )
  end

  context "#suggestions" do
    should "surface the assessee's manager, peers, and direct reports" do
      relations = query.suggestions.to_h { |c| [ c.person.id, c.relation ] }
      assert_equal :manager, relations[@manager.id]
      assert_equal :peer, relations[@peer.id]
      assert_equal :report, relations[@report.id]
    end

    should "surface the assessee themselves when the requester is someone else" do
      cands = query(requester: @manager).suggestions
      assert_equal :assessee, cands.find { |c| c.person.id == @assessee.id }&.relation
    end

    should "exclude the requester and skip unrelated people" do
      ids = query(requester: @peer).suggestions.map { |c| c.person.id }
      assert_includes ids, @assessee.id        # a manager/peer can ask the assessee for more evidence
      assert_not_includes ids, @peer.id        # requester excluded even though a peer
      assert_not_includes ids, @stranger.id
    end

    should "leave out forgotten neighbours" do
      [ @manager, @peer ].each { |person| person.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current) }
      ids = query.suggestions.map { |c| c.person.id }
      assert_not_includes ids, @manager.id
      assert_not_includes ids, @peer.id
      assert_includes ids, @report.id
    end

    should "flag a suggestion that already has a pending request on this cell" do
      pending_request_from(@peer)
      peer = query.suggestions.find { |c| c.person.id == @peer.id }
      assert peer.already_requested
      report = query.suggestions.find { |c| c.person.id == @report.id }
      assert_not report.already_requested
    end
  end

  context "#search" do
    should "match by name (case-insensitive, partial)" do
      ids = query.search("pri").map { |c| c.person.id }
      assert_includes ids, @peer.id
      assert_not_includes ids, @manager.id
    end

    should "match by email" do
      ids = query.search("sam@exam").map { |c| c.person.id }
      assert_includes ids, @stranger.id
    end

    should "never return the requester" do
      assert_empty query.search("Alex").map { |c| c.person.id } # requester == assessee here
      assert_empty query(requester: @manager).search("Morgan").map { |c| c.person.id } # requester
    end

    should "let a non-assessee requester find the assessee" do
      ids = query(requester: @manager).search("Alex").map { |c| c.person.id }
      assert_includes ids, @assessee.id
    end

    should "flag an already-pending match instead of hiding it" do
      pending_request_from(@stranger)
      cand = query.search("Sam").find { |c| c.person.id == @stranger.id }
      assert cand.already_requested
    end

    should "return nothing for a blank query" do
      assert_empty query.search("")
      assert_empty query.search(nil)
    end

    should "treat LIKE wildcards literally" do
      assert_empty query.search("%")
    end
  end
end
