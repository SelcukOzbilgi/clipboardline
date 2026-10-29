# ClipBoardLine — SelcukOzbilgi kişisel fork'u

Bu repo `orkunisitmak/clipboardline` reposunun kişisel macOS fork'udur. Kurallar
`CLAUDE.md` içinde; plan `docs/fork/PLAN.md`, inceleme `docs/fork/REVIEW.md`.

- Doğrudan `main`'e push yok: `efe/<konu>` dalı, PR yalnız
  `SelcukOzbilgi/clipboardline`'a. Upstream'e PR, issue veya yorum açılmaz.
- Hedef yalnız macOS. `windows/` upstream merge'leri için durur, bakımı yapılmaz.
- Uygulama yalnız `bash scripts/build-fork.sh` ile derlenir; `swift run` kullanılmaz.
- Upstream güncelleme kanalı fork'ta kapalı kalır (`ForkUpdateIsolationTests`).
- Değişiklikten sonra `swift test` ve `swift scripts/check-strings.swift`.
