require_relative 'models/user.generated'
class User
  def self.all
    [User.new(1,'alice@example.com','Alice'),User.new(2,'bob@example.com','Bob')]
  end
end
