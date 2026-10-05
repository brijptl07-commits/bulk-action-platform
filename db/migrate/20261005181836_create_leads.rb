class CreateLeads < ActiveRecord::Migration[7.0]
  def change
    create_table :leads do |t|
      t.string :name, null: false
      t.string :email
      t.string :company_name
      t.string :source
      t.integer :score
      t.string :status, null: false, default: "new"
      t.timestamps
    end

    add_index :leads, :email
    add_index :leads, :status
    add_index :leads, :source
  end
end
