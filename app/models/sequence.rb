class Sequence < ApplicationRecord
  # Durable, strictly increasing counter shared by all processes.
  # MySQL's LAST_INSERT_ID(expr) makes increment-and-read atomic and connection-scoped.
  def self.next(name)
    quoted = connection.quote(name.to_s)
    connection.execute("INSERT IGNORE INTO sequences (name, value) VALUES (#{quoted}, 0)")
    connection.execute("UPDATE sequences SET value = LAST_INSERT_ID(value + 1) WHERE name = #{quoted}")
    connection.select_value("SELECT LAST_INSERT_ID()").to_i
  end
end
