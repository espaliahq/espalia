# frozen_string_literal: true

require "test_helper"

# The recipient directory behind "who can I give feedback to?": search by
# name or email over people with an assignment, org-neighbour suggestions
# when no query is given, the giver's relationship to each row, and the
# exclusions (the giver, the unassigned, the inactive).
class Operations::Assessments::FeedbackRecipientsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, name: "Morgan Manager", email: "morgan@example.com")
      @giver   = create(:person, tenant: @tenant, email: @user.email, name: "Gia Giver", manager_id: @manager.id)
      @peer    = create(:person, tenant: @tenant, name: "Priya Peer", email: "priya@example.com", manager_id: @manager.id)
      @report  = create(:person, tenant: @tenant, name: "Rafael Report", email: "rafa@example.com", manager_id: @giver.id)
      @stranger = create(:person, tenant: @tenant, name: "Priyanka Stranger", email: "priyanka@example.com")
      @unassigned = create(:person, tenant: @tenant, name: "Una Unassigned", email: "una@example.com", manager_id: @manager.id)
      @gone = create(:person, tenant: @tenant, name: "Priam Gone", email: "priam@example.com", status: "inactive")
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @giver, role: :member)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Engineering")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      role  = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")

      pd = PersonDevelopment::CommandHandler.new
      [ @manager, @giver, @peer, @report, @stranger, @gone ].each do |person|
        pd.assign_to_framework(person.id, @framework_id, role.role_id, level.level_id)
      end
    end

    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @giver)
  end

  def call_op(**params)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::FeedbackRecipients.call(context: @context, params: params)
    end
  end

  def names(result) = result[:recipients].map { |r| r.dig(:person, :name) }

  context "search" do
    should "match name or email, excluding the giver, the unassigned and the inactive" do
      # Order-insensitive: the name sort follows the database's collation, and
      # CI's locale ranks "Priyanka" before "Priya " where a byte order does not.
      assert_equal [ "Priya Peer", "Priyanka Stranger" ], names(call_op(query: "pri")).sort
      assert_equal [ "Rafael Report" ], names(call_op(query: "rafa@"))
      assert_empty names(call_op(query: "Gia"))
      assert_empty names(call_op(query: "Una"))
    end

    should "carry the assignment id, framework, role and level for the write that follows" do
      row = call_op(query: "Priya Peer")[:recipients].first
      assignment = ActsAsTenant.with_tenant(@tenant) { PersonFrameworkAssignment.for_person(@peer.id).first }
      assert_equal assignment.id, row[:assignment_id]
      assert_equal "Engineering", row.dig(:framework, :name)
      assert_equal "E", row.dig(:role, :code)
      assert_equal 2, row.dig(:level, :ordinal)
      assert_equal "E2", row.dig(:level, :code)
      assert_equal "priya@example.com", row.dig(:person, :email)
    end

    should "treat LIKE wildcards literally" do
      assert_empty names(call_op(query: "%"))
    end

    should "cap the rows, counting a person assessed twice as two" do
      ActsAsTenant.with_tenant(@tenant) do
        other_framework = SecureRandom.uuid_v7
        create(:framework_state, framework_id: other_framework, name: "Design")
        rf = create(:framework_role_family, framework_id: other_framework, name: "Design")
        role = create(:framework_role, role_family_id: rf.role_family_id, name: "Designer", code: "D", track: "ic")
        level = create(:framework_level, role_id: role.role_id, ordinal: 1, title: "Junior", code: "D1")
        PersonDevelopment::CommandHandler.new.assign_to_framework(@peer.id, other_framework, role.role_id, level.level_id)
      end
      assert_equal 1, call_op(query: "e", limit: 1)[:recipients].size
      assert_equal 2, call_op(query: "Priya Peer")[:recipients].size
    end
  end

  context "relationship" do
    should "say who reports to whom from the giver's side" do
      by_name = call_op(query: "e")[:recipients].to_h { |r| [ r.dig(:person, :name), r[:relationship] ] }
      assert_equal "manager", by_name["Morgan Manager"]
      assert_equal "report", by_name["Rafael Report"]
      assert_equal "peer", by_name["Priya Peer"]
      assert_equal "peer", by_name["Priyanka Stranger"]
    end
  end

  context "suggestions" do
    should "offer the manager, peers and reports with assignments when no query is given" do
      assert_equal [ "Morgan Manager", "Priya Peer", "Rafael Report" ], names(call_op)
    end
  end

  context "policy" do
    should "deny a caller with no person" do
      ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
      assert_raises(Pundit::NotAuthorizedError) do
        ActsAsTenant.with_tenant(@tenant) do
          Operations::Assessments::FeedbackRecipients.call(context: ctx, params: { query: "p" })
        end
      end
    end
  end
end
