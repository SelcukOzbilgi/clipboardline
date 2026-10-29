# Efe'nin ClipBoardLine fork'u

Upstream `orkunisitmak/clipboardline` (MIT; kendisi `alejandrobujan/tendedero` fork'u) üzerinden kişisel Mac uygulaması. Görünen ad **ClipBoardLine** olarak kalır; yalnız arka plan kimliği (bundle ID, veri klasörü, defaults) ayrıdır.

## Bu dosya upstream kurallarının önüne geçer

`AGENTS.md` upstream'den geldi ve upstream'in kendi deposu için yazıldı: doğrudan `main`'e push, Windows eşliği, resmi release kapıları. **Bu fork'ta geçerli değil.** Burada geçerli olan:

- `origin` = `SelcukOzbilgi/clipboardline` (fork, public). `gh` varsayılanı bu repo.
- `upstream` = `orkunisitmak/clipboardline`; push kapalı. Upstream'e PR, issue veya yorum açma.
- Çalışma dalları `efe/<konu>`; PR'lar her zaman `--repo SelcukOzbilgi/clipboardline --base main`. Doğrudan `main`'e push yok; merge kararı Efe'nin.
- Hedef yalnız macOS. `windows/` olduğu gibi kalır (upstream merge'leri kolay kalsın diye silinmez), ama bakımı yapılmaz.

## Belgeler

- `docs/fork/PLAN.md`: kararlar, kimlik değerleri, aşamalar, build ve imza komutları.
- `docs/fork/REVIEW.md`: upstream 1.7.8 (00452eb) inceleme raporu, bulgular ve öncelikler.

## Kurallar

- **Fork değişikliklerini küçük ve eklemeli tut**, `git merge upstream/main` kolay kalsın. Kimlik değişiklikleri mümkün olduğunca `scripts/build-community.sh` içinde; upstream dosyalarını silmek yerine devre dışı bırakmak tercih edilir.
- **Uygulamayı yalnız `scripts/build-community.sh` ile derle.** `swift run`/paketlenmemiş `Tendedero` binary'si resmi uygulamanın veri klasörüne yazar.
- Upstream güncelleme kanalı (Sparkle feed, GitHub API updater, credential broker) fork build'inde asla etkin olmamalı; bunu bir test korur.
- Gerçek pano içeriği, tercih dosyaları, `library.sqlite`, imza anahtarı veya `.p12` commit'e girmez.
- Değişiklikten sonra: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (Command Line Tools'ta XCTest yok) ve `swift scripts/check-strings.swift`. Sonucu söyle; geçmeyen testi gizleme.
