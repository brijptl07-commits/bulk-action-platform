class CreateCompanies < ActiveRecord::Migration[7.0]
  def change
    create_table :companies do |t|
      t.string :name, null: false
      t.string :domain
      t.string :industry
      t.integer :employee_count
      t.string :status, null: false, default: "prospect"
      t.timestamps
    end

    add_index :companies, :domain
    add_index :companies, :status
    add_index :companies, :industry
  end
end
