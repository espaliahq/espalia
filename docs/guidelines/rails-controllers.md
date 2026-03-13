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
