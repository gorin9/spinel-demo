# 人が書く側 — business logic だけ.
# データ表現は user.generated.rb 側で attr_accessor 等が定義される想定だが,
# このデモでは spnl-schema 経由ではなく軽量な POJO のみで demo する.
class User
  attr_accessor :id, :email, :name

  def initialize(id, email, name)
    @id = id
    @email = email
    @name = name
  end

  def display_name
    "Mr/Ms. " + @name
  end

  def admin?
    @email.end_with?("@admin.example.com")
  end

  # Spinel-friendly: class method 経由で Array<User> を取得する.
  # 本番では spnl-web の SQLite ラッパが返す.
  def self.all
    out = []
    out.push(User.new(1, "alice@example.com",      "Alice"))
    out.push(User.new(2, "bob@example.com",        "Bob"))
    out.push(User.new(3, "root@admin.example.com", "Root"))
    out
  end
end
