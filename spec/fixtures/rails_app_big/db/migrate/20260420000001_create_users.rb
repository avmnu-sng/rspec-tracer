# frozen_string_literal: true

class CreateUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :users do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.string :role, null: false, default: 'member'
      t.datetime :activated_at

      t.timestamps
    end

    add_index :users, :email, unique: true
  end
end
