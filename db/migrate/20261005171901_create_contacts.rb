class CreateContacts < ActiveRecord::Migration[7.0]
  def change
    create_table :contacts do |t|
      t.string :name, null: false
      t.string :email
      t.integer :age
      t.string :status, null: false, default: "lead"
      t.timestamps
    end

    add_index :contacts, :email
    add_index :contacts, :status
  end
end
