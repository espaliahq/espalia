require "test_helper"

class UserTest < ActiveSupport::TestCase
  subject { build(:user) }

  context "associations" do
    should have_many(:tenant_users).dependent(:destroy)
    should have_many(:tenants).through(:tenant_users)
  end

  context "validations" do
    should validate_presence_of(:email)
    should validate_uniqueness_of(:email).case_insensitive
  end

  context "global_admin?" do
    should "return false by default" do
      assert_not subject.global_admin?
    end

    should "return true when global_admin is set" do
      user = build(:user, global_admin: true)
      assert user.global_admin?
    end
  end
end
