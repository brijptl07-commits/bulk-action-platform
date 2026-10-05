module Ui
  class ContactsController < ApplicationController
    def index
      @status = params[:status].presence
      scope = Contact.order(:id)
      scope = scope.where(status: @status) if @status
      scope = scope.where("email LIKE ?", "%#{Contact.sanitize_sql_like(params[:q])}%") if params[:q].present?
      @contacts = scope.page(params[:page]).per(50)
      @counts = Contact.group(:status).count
    end
  end
end
