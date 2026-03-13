# Service Object Standards

**Only use service objects for complex cross-model orchestration. Prefer model methods and concerns.**

## Requirements

- Place in `app/services/`
- Name with verb + noun ending in "Service": `CreateUserService`, `SyncHrisDataService`
- Use `class Service::ClassName` (not nested modules)
- Accept parameters via `initialize`
- Implement a `run` (or `call`) method as the main entry point
- Return a result object or the expected value
- Include YARD documentation for all public methods
- Wrap multi-model operations in transactions
- Single responsibility — one service, one job

## Example

```ruby
# frozen_string_literal: true

# Creates a new user with default account setup.
#
# @example
#   user = CreateUserService.new(email: "test@example.com", name: "Test").run
#
class CreateUserService
  # @param attributes [Hash] User attributes
  # @option attributes [String] :email
  # @option attributes [String] :name
  # @option attributes [String] :account_name Defaults to "My Account"
  def initialize(attributes)
    @attributes = attributes
    @account_name = attributes.delete(:account_name) || "My Account"
  end

  # @return [User] The created user
  # @raise [ActiveRecord::RecordInvalid] If validation fails
  def run
    User.transaction do
      create_user
      create_account
      create_account_user
    end
    @user
  end

  private

  def create_user
    @user = User.create!(@attributes)
  end

  def create_account
    @account = Account.create!(name: @account_name, owner: @user)
  end

  def create_account_user
    AccountUser.create!(account: @account, user: @user, admin: true)
  end
end
```

## Anti-patterns

```ruby
# Bad - nested modules, positional args, no docs, no transaction
module Services
  module Users
    class Create
      def initialize(email, name)
        @email = email
        @name = name
      end

      def call
        user = User.new(email: @email, name: @name)
        user.save
        Account.create(name: "My Account")  # not wrapped in transaction
        user
      end
    end
  end
end
```
