# frozen_string_literal: true

require "test_helper"

# An account's link to its person as events on the grants stream (#539 2b).
class AccountGrants::LinksTest < ActiveSupport::TestCase
  LINK_EVENTS = [ AccountGrants::Events::AccountLinkedToPerson, AccountGrants::Events::AccountUnlinkedFromPerson ].freeze

  setup do
    @tenant = create(:tenant)
    as_tenant do
      @actor = create(:person, tenant: @tenant)
      @ada = create(:person, tenant: @tenant)
      @bo = create(:person, tenant: @tenant)
      @account = create(:tenant_user, tenant: @tenant, person: nil)
      @other = create(:tenant_user, tenant: @tenant, person: nil)
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def handler = AccountGrants::CommandHandler.new

  def links = as_tenant { AccountGrants::Repository.new.reading_locked(&:links) }

  def link_events
    Rails.configuration.event_store.read.stream(EventStreamNaming.tenant_account_grants_stream(tenant: @tenant)).of_type(LINK_EVENTS).to_a
  end

  def column(account) = TenantUser.unscoped.find(account.id).person_id

  def today = @tenant.today.iso8601

  context "link_to!" do
    should "record the link with its match and actor, and write the column" do
      as_tenant { @account.link_to!(@ada, match: :admin, linked_by_id: @actor.id) }

      assert_equal({ @account.id => @ada.id }, links)
      assert_equal({ tenant_user_id: @account.id, person_id: @ada.id, effective_on: today, linked_by_id: @actor.id,
                     match: "admin", already_held: false }, link_events.sole.data)
      assert_equal @ada.id, column(@account)
      assert_equal @ada.id, @account.person_id
      assert_not @account.changed?
    end

    should "write nothing for the link an account already has" do
      as_tenant { 2.times { @account.link_to!(@ada, match: :sign_in) } }

      assert_equal 1, link_events.size
    end

    should "refuse a person another account holds, and an account linked to someone else" do
      as_tenant { @account.link_to!(@ada, match: :sign_in) }

      assert_raises(AccountGrants::Aggregate::LinkTaken) { as_tenant { @other.link_to!(@ada, match: :hris_email) } }
      assert_raises(AccountGrants::Aggregate::LinkTaken) { as_tenant { @account.link_to!(@bo, match: :hris_email) } }
      assert_nil column(@other)
      assert_equal @ada.id, column(@account)
    end

    should "refuse a forgotten person" do
      @bo.update_columns(name: Person::FORMER_MEMBER, email: nil, external_id: nil, forgotten_at: Time.current)

      assert_raises(AccountGrants::Aggregate::PersonForgotten) { as_tenant { @account.link_to!(@bo, match: :sign_in) } }
      assert_nil column(@account)
    end

    should "refuse a match it doesn't know" do
      assert_raises(ArgumentError) { as_tenant { @account.link_to!(@ada, match: :guess) } }
    end

    should "act on the link the stream records, whatever the column says" do
      as_tenant { @account.link_to!(@ada, match: :sign_in) }
      @account.update_columns(person_id: nil)
      @other.update_columns(person_id: @bo.id)

      assert_raises(AccountGrants::Aggregate::LinkTaken) { as_tenant { @other.link_to!(@ada, match: :sign_in) } }
      as_tenant { @other.link_to!(@bo, match: :sign_in) }

      assert_equal({ @account.id => @ada.id, @other.id => @bo.id }, links)
      assert_equal %w[sign_in sign_in], link_events.map { it.data[:match] }
    end

    should "unlink an account from a person since destroyed, then link it" do
      as_tenant do
        @account.link_to!(@ada, match: :sign_in)
        Person.find(@ada.id).destroy!
        TenantUser.find(@account.id).link_to!(@bo, match: :sign_in)
      end

      assert_equal({ @account.id => @bo.id }, links)
      assert_equal %w[sign_in cleared sign_in], link_events.map { it.data[:match] || it.data[:reason] }
      assert_equal @bo.id, column(@account)
    end
  end

  context "unlink_forgotten" do
    should "unlink every account linked to the person, and return the ones the table holds" do
      as_tenant { @account.link_to!(@ada, match: :sign_in) }

      ids = as_tenant { handler.unlink_forgotten(@ada.id) }

      assert_equal [ @account.id ], ids
      assert_empty links
      assert_equal "forgotten", link_events.last.data[:reason]
      assert_nil column(@account)
    end

    should "record a link only the column holds, then unlink it" do
      @other.update_columns(person_id: @ada.id)

      ids = as_tenant { handler.unlink_forgotten(@ada.id) }

      assert_equal [ @other.id ], ids
      assert_equal [ true, "forgotten" ], link_events.map { it.data.key?(:already_held) ? it.data[:already_held] : it.data[:reason] }
      assert_empty links
    end

    should "then refuse to link the person again" do
      as_tenant { @other.link_to!(@ada, match: :sign_in) }
      as_tenant { handler.unlink_forgotten(@ada.id) }

      assert_raises(AccountGrants::Aggregate::PersonForgotten) { as_tenant { @account.link_to!(@ada, match: :admin) } }
    end
  end

  context "the projection" do
    should "keep a link the stream doesn't record through a reset, and set the ones it does" do
      as_tenant { @account.link_to!(@ada, match: :sign_in) }
      @account.update_columns(person_id: @bo.id)
      @other.update_columns(person_id: @bo.id)

      AccountGrants::Projections::AccountFlags.reset!(tenant: @tenant)

      assert_equal [ @ada.id, @bo.id ], [ column(@account), column(@other) ]
    end

    should "leave the link clear through a reset when the stream's person was destroyed" do
      as_tenant do
        @account.link_to!(@ada, match: :sign_in)
        Person.find(@ada.id).destroy!
      end

      AccountGrants::Projections::AccountFlags.reset!(tenant: @tenant)

      assert_nil column(@account)
    end

    should "leave an account the previous release erased out of a reset, though the stream still links it" do
      as_tenant { @account.link_to!(@ada, match: :sign_in) }
      Person.unscoped.where(id: @ada.id).update_all(name: Person::FORMER_MEMBER, email: nil, external_id: nil, forgotten_at: Time.current)
      @account.update_columns(person_id: nil, forgotten_at: Time.current)

      AccountGrants::Projections::AccountFlags.reset!(tenant: @tenant)

      assert_nil column(@account)
    end

    should "clear only the person it unlinked" do
      as_tenant { @account.link_to!(@ada, match: :sign_in) }
      @account.update_columns(person_id: @bo.id)

      as_tenant { handler.unlink_forgotten(@ada.id) }

      assert_equal @bo.id, column(@account)
    end
  end
end
