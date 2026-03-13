# frozen_string_literal: true

class PagesController < ApplicationController
  # GET /
  def index
    render Views::Pages::IndexView.new
  end
end
