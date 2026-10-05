module Api
  class ContactsController < BaseController
    # GET /contacts?status=lead&email=contact1@example.com&page=1
    def index
      scope = Contact.order(:id)
      scope = scope.where(status: params[:status]) if params[:status].present?
      scope = scope.where(email: params[:email]) if params[:email].present?
      scope = scope.page(page).per(per_page)

      render json: { data: scope.as_json(only: %i[id name email age status updated_at]), meta: pagination(scope) }
    end
  end
end
