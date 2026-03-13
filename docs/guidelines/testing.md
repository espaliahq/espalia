# Testing Standards

## Framework

- **Minitest** with Shoulda Matchers + FactoryBot
- These patterns apply to **new tests only** — do not rewrite existing tests
- Do NOT pipe test output: run `bin/rails test` directly, never `bin/rails test | cat`
- Use `assert_nil value` (not `assert_equal nil, value`)

## Test Locations

| Type | Location | Base Class |
|------|----------|------------|
| Models | `test/models/` | `ActiveSupport::TestCase` |
| Controllers | `test/controllers/` | `ActionDispatch::IntegrationTest` |
| System | `test/system/` | `ApplicationSystemTestCase` |
| Components | `test/components/` | `ComponentTestCase` |

## New Test Pattern (Shoulda + FactoryBot)

```ruby
class UserTest < ActiveSupport::TestCase
  subject { build(:user) }

  context "validations" do
    should validate_presence_of(:email)
    should validate_uniqueness_of(:email).case_insensitive
  end

  context "associations" do
    should have_many(:posts).dependent(:destroy)
  end

  context "when archived" do
    subject { build(:user, archived_at: Time.current) }

    should "not be active" do
      assert_not subject.active?
    end
  end

  context "#full_name" do
    should "return first and last name" do
      user = build(:user, first_name: "John", last_name: "Doe")
      assert_equal "John Doe", user.full_name
    end
  end
end
```

## Component Testing

```ruby
class Kit::ButtonTest < ComponentTestCase
  context "Kit::Button" do
    should "render a button with label" do
      html = render_component(Kit::Button.new("Save"))
      assert_selector html, "button", text: "Save"
    end

    should "render with primary variant by default" do
      html = render_component(Kit::Button.new("Save"))
      assert_selector html, "button.btn.btn-primary"
    end
  end
end
```

## Testing store_model Objects

Test the store_model class directly AND integration via the parent model:

```ruby
# Unit test the store_model class
class ShippingAddressTest < ActiveSupport::TestCase
  subject { ShippingAddress.new(street: "123 Main St", city: "Portland") }

  context "validations" do
    should validate_presence_of(:street)
    should validate_presence_of(:city)
  end
end

# Integration test via parent model
class OrderTest < ActiveSupport::TestCase
  context "shipping_address" do
    should "validate nested address" do
      order = build(:order)
      order.shipping_address = ShippingAddress.new(street: nil, city: "Seattle")
      assert_not order.valid?
    end
  end
end
```

## Visual Verification with Screenshots

System tests support automatic screenshot capture via `SCREENSHOTS=1`. Use the `/screenshot-test` skill to run system tests and visually examine every captured screenshot. **Use this to verify any new or modified front-end functionality.**

```bash
SCREENSHOTS=1 bin/rails test test/system/foo.rb
# Screenshots saved to: tmp/screenshots/{TestClass}/{test_name}/{001_action.png}
```

## Rules

- Use `subject { }` to define the object under test
- Use `context` blocks to group related tests
- Use `should` matchers for validations, associations, callbacks
- Use FactoryBot (`build`, `create`, `build_stubbed`) — not fixtures for new tests
- Test happy paths, sad paths, and edge cases
