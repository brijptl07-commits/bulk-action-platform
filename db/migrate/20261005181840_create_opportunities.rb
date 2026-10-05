class CreateOpportunities < ActiveRecord::Migration[7.0]
  def change
    create_table :opportunities do |t|
      t.string :name, null: false
      t.references :company, foreign_key: true
      t.decimal :amount, precision: 12, scale: 2
      t.string :stage, null: false, default: "prospecting"
      t.integer :probability
      t.date :close_date
      t.timestamps
    end

    add_index :opportunities, :stage
  end
end
