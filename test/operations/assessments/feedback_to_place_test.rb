# frozen_string_literal: true

require "test_helper"

class Operations::Assessments::FeedbackToPlaceTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @me      = create(:person, tenant: @tenant, email: @user.email, name: "Morgan Manager")
      @direct  = create(:person, tenant: @tenant, name: "Dana Direct", manager: @me)
      @deep    = create(:person, tenant: @tenant, name: "Sky Skiplevel", manager: @direct)
      @deeper  = create(:person, tenant: @tenant, name: "Del Delegated", manager: @direct)
      @other_lead = create(:person, tenant: @tenant, name: "Olu Otherlead")
      @seconded = create(:person, tenant: @tenant, name: "Sam Seconded", manager: @other_lead)
      @stranger = create(:person, tenant: @tenant, name: "Stan Stranger")
      @peer = create(:person, tenant: @tenant, name: "Priya Peer")
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @me, role: :member)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Engineering")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")

      @pd = PersonDevelopment::CommandHandler.new
      [ @me, @direct, @deep, @deeper, @seconded, @stranger ].each do |person|
        @pd.assign_to_framework(person.id, @framework_id, role.role_id, level.level_id)
      end
      @pd.delegate_manager_rating(@seconded.id, @framework_id, @me.id, granted_by_id: @other_lead.id)
      @pd.delegate_manager_rating(@deeper.id, @framework_id, @me.id, granted_by_id: @direct.id)

      @about_me = record!(@me, "About me.")
      @about_direct = record!(@direct, "About Dana.")
      @about_seconded = record!(@seconded, "About Sam.")
      @about_deeper = record!(@deeper, "About Del.")
      @about_deep = record!(@deep, "About Sky.")
      @mine = record!(@direct, "I wrote this.", author: @me)
      @about_stranger = record!(@stranger, "About Stan.")
    end

    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @me)
  end

  def record!(person, content, author: @peer, **extra)
    id = SecureRandom.uuid_v7
    @pd.record_evidence(person.id, @framework_id, id, source: "peer", evidence_type: "peer_feedback",
      content: content, author_id: author.id, **extra)
    id
  end

  def call_op(**params)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::FeedbackToPlace.call(context: @context, params: params)
    end
  end

  def ids(rows) = rows.map { |row| row[:evidence_id] }

  should "list the team by default: direct reports and delegations, never the viewer's own writing" do
    result = call_op

    assert_equal "team", result[:scope]
    assert_equal [ @about_direct, @about_seconded, @about_deeper ], ids(result[:items])
  end

  should "add everyone deeper in the subtree for the org scope" do
    result = call_op(scope: "org")

    assert_equal "org", result[:scope]
    assert_equal [ @about_direct, @about_seconded, @about_deeper, @about_deep ], ids(result[:items])
  end

  should "keep feedback about the viewer in its own list, whatever the scope" do
    assert_equal [ @about_me ], ids(call_op[:about_you])
    assert_equal [ @about_me ], ids(call_op(scope: "org")[:about_you])
  end

  should "count both views and say the org reaches beyond the team" do
    result = call_op

    assert_equal({ team: 3, org: 4 }, result[:counts])
    assert result[:beyond_team]
  end

  should "say the org reaches no further for a manager with direct reports only" do
    ActsAsTenant.with_tenant(@tenant) do
      @deep.update!(manager: @stranger)
      @deeper.update!(manager: @stranger)
    end
    result = call_op(scope: "org")

    assert_not result[:beyond_team]
    assert_equal result[:counts][:team], result[:counts][:org]
  end

  should "skip the org walk while nothing about anyone else is waiting" do
    ActsAsTenant.with_tenant(@tenant) { EvidenceItem.where.not(id: @about_me).delete_all }
    result = call_op(scope: "org")

    assert_not result[:beyond_team]
    assert_equal({ team: 0, org: 0 }, result[:counts])
    assert_equal [ @about_me ], ids(result[:about_you])
  end

  should "describe each item: who and which assignment it is about, kind, origin, date and an excerpt" do
    row = call_op[:items].first
    assignment = ActsAsTenant.with_tenant(@tenant) { PersonFrameworkAssignment.find_by(person_id: @direct.id) }

    assert_equal assignment.id, row[:assignment_id]
    assert_equal({ id: @direct.id, name: "Dana Direct" }, row[:person])
    assert_equal({ id: @framework_id, name: "Engineering" }, row[:framework])
    assert_equal "peer_feedback", row[:kind]
    assert_equal({ system: "growthos", label: "GrowthOS", url: nil }, row[:origin])
    assert_equal({ id: @peer.id, name: "Priya Peer" }, row[:author])
    assert_equal "About Dana.", row[:excerpt]
    assert row[:recorded_at].present?
  end

  should "mark imported feedback with its peer system and the original's address" do
    imported = ActsAsTenant.with_tenant(@tenant) do
      record!(@direct, "Great **incident** call. #{'More detail. ' * 40}",
        external_reference: { system: "chip", external_id: "c-1", url: "https://chip.example.com/f/1",
                              metadata: { given_at: "2026-10-18T09:00:00Z" } })
    end
    row = call_op[:items].find { |r| r[:evidence_id] == imported }

    assert_equal({ system: "chip", label: "Chip", url: "https://chip.example.com/f/1" }, row[:origin])
    assert row[:excerpt].start_with?("Great incident call.")
    assert_operator row[:excerpt].length, :<=, Operations::Assessments::FeedbackToPlace::EXCERPT_LENGTH
  end

  should "drop an item once it is placed" do
    ActsAsTenant.with_tenant(@tenant) do
      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      @pd.add_evidence_link(@direct.id, @framework_id, @about_direct,
        capability_stable_id: cap.stable_id, level_ordinal: 2, linked_by_id: @me.id, valence: "demonstrated")
    end

    assert_not_includes ids(call_op[:items]), @about_direct
  end

  should "refuse an unknown scope" do
    assert_raises(Operations::Base::ParameterError) { call_op(scope: "tenant") }
  end

  should "refuse a member with no person record" do
    context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
    assert_raises(Pundit::NotAuthorizedError) do
      ActsAsTenant.with_tenant(@tenant) { Operations::Assessments::FeedbackToPlace.call(context: context) }
    end
  end
end
