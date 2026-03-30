# Rails Controller Standards

## Requirements

- Add HTTP verb and path comments above each action: `# GET /categories`
- Use resource-based naming, RESTful conventions
- Use `before_action` for common setup
- Namespace API controllers under `Api::V1`
- Use `respond_to` for format handling (HTML/JSON)
- Use `pagy` for pagination: `@pagy, @resources = pagy(Resource.sort_by_params(params[:sort], sort_direction))`
- Use `status: :see_other` for redirects after DELETE
- Use `status: :unprocessable_content` for failed creates/updates (RFC 9110)
- Handle not found: `rescue ActiveRecord::RecordNotFound`
- Use `params.expect(:resource)` instead of `params.require`
- Include authentication callbacks where needed
- Render Phlex views: `render Views::Resource::ActionView.new(resource:)`

## Example

```ruby
class CategoriesController < ApplicationController
  before_action :set_category, only: [:show, :edit, :update, :destroy]

  # GET /categories
  def index
    @pagy, @categories = pagy(Category.sort_by_params(params[:sort], sort_direction))
    render Views::Categories::IndexView.new(pagy: @pagy, categories: @categories)
  end

  # POST /categories
  def create
    @category = Category.new(category_params)
    if @category.save
      redirect_to @category, notice: "Category was successfully created."
    else
      render :new, status: :unprocessable_content
    end
  end

  # DELETE /categories/:id
  def destroy
    @category.destroy
    redirect_to categories_path, status: :see_other, notice: "Deleted."
  end

  private

  def set_category
    @category = Category.find(params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    redirect_to categories_path
  end

  def category_params
    params.expect(category: [:name, :description])
  end
end
```

## Authorization (NON-NEGOTIABLE)

**Every controller action MUST call `authorize`.** No exceptions — even read-only actions need explicit authorization to prevent accidental exposure when roles change.

Pundit receives an `AuthorizationContext` (not a raw User) via `pundit_user`, providing access to the full identity chain: User → TenantUser → Person. See `docs/guidelines/authorization.md` for the full permission model.

### Patterns

```ruby
# Collection action — authorize on the model class
def index
  authorize FrameworkState::Framework, :index?
  @frameworks = FrameworkState::Framework.all
end

# Instance action — authorize on the record
def show
  authorize @framework
end

# Custom action name — use domain-specific names, not generic CRUD
def create
  authorize @framework, :create_illustration?
end

# Pass permission flags to views — don't expose policy objects
def show
  authorize @framework
  render Views::Frameworks::ShowView.new(
    framework: @framework,
    is_admin: policy(@framework).admin?
  )
end
```

### Denial handling

`ApplicationController` rescues `Pundit::NotAuthorizedError` with a redirect-back and flash alert. No per-controller handling needed.

### Authorization anti-patterns

```ruby
# Bad — manual before_action instead of Pundit
before_action :authorize_admin!
def authorize_admin!
  redirect_to root_path unless current_user.global_admin?
end

# Bad — "authorization is enforced in the command handler"
# Command handlers do NOT check permissions — controllers must

# Bad — inline role check instead of policy
def create
  return head(:forbidden) unless current_tenant_user&.admin?
end
```

## Anti-patterns

```ruby
# Bad - no HTTP verb comment, params.require, no pagination, wrong redirect status
class CategoriesController < ApplicationController
  def index
    @categories = Category.all
  end

  def create
    @category = Category.new(params.require(:category).permit(:name))
    if @category.save
      redirect_to @category
    else
      render :new  # missing status:
    end
  end
end
```
