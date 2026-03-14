# frozen_string_literal: true

# An organisational entity representing a person in the org chart.
#
# A Person may be created by HRIS sync or manually. They are linked to a User
# (via TenantUser) for authentication, but many Persons won't have a corresponding
# User (e.g. HRIS-imported people who haven't logged in yet).
#
# @example
#   person = Person.new(email: "alice@example.com", tenant: tenant)
#   person.name = "Alice Smith"
#
class Person < ApplicationRecord
  acts_as_tenant :tenant

  has_prefix_id :per

  translates :name

  belongs_to :tenant
  belongs_to :manager, class_name: "Person", optional: true
  has_many :direct_reports, class_name: "Person", foreign_key: :manager_id, dependent: :nullify, inverse_of: :manager
  has_one :tenant_user, dependent: :nullify
  has_one :user, through: :tenant_user

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true
end
