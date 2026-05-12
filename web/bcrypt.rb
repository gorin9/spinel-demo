# web/bcrypt.rb — bcrypt パスワードハッシュ (Tier 3 #14)
#
# 依存: H.sp_bcrypt_hash, H.sp_bcrypt_verify (libxcrypt 経由)
# 用途: ユーザパスワードの hash 保存 + 検証

# Note: 関数名は "bcrypt_*" を避ける (Spinel が def を sp_bcrypt_* に
# mangle するため FFI 名 sp_bcrypt_hash と衝突する)。"bc_*" を使う。

# password を bcrypt ハッシュにする。cost は 4〜31 (10 が典型)。
def bc_hash(password, cost)
  H.sp_bcrypt_hash(password, cost)
end

# password と stored_hash が一致するか。
def bc_verify(password, stored)
  H.sp_bcrypt_verify(password, stored) == 1
end
