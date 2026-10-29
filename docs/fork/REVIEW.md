# Upstream inceleme raporu: ClipBoardLine 1.7.8

İncelenen: `orkunisitmak/clipboardline` @ `00452eb` (2026-10-28), resmi Mac paketi `ClipboardLine-1.7.8-build78.zip`.
Yöntem: dört alt ajan (mimari/fork hijyeni, güvenlik/gizlilik, REA ile release paketi, kod kalitesi/testler). Repo kodu, betikleri ve uygulama çalıştırılmadı; yalnız statik okuma, `codesign`/`spctl`/`stapler`, REA ve kopyalanmış lockfile üzerinde `npm audit` (0 açık).

## Özet

Mac çekirdeği özenli ve iyi test edilmiş (639 XCTest, gerçek `LibraryStore`/`Line` üzerinde). Telemetri yok, pano içeriği cihaz dışına çıkmıyor, güncelleme zinciri ve link getirme katmanı iyi sertleştirilmiş. İki ciddi konu: geçmiş hiç kalıcı silinmiyor ve kopyalanan URL'ler resmi build'de otomatik getiriliyor.

## Bulgular (önem sırası)

| # | Önem | Bulgu | Yer | Fork'ta |
|---|---|---|---|---|
| 1 | Yüksek | Geçmiş asla kalıcı silinmiyor. Saklama süresi ve "Çöp'e taşı" yalnız `deletedAt` set eder; metin/URL/OCR `library.sqlite`'ta (WAL, `secure_delete` yok) ve Time Machine'de kalır. Görsel dosyaları Finder Çöp'üne gider. Migration yedekleri (`Library/Backups`) hiç budanmaz. Mac'te "Çöp'ü boşalt" yok. | `LibraryStore.swift:766`, `:889-902`, `:273-290`; `HistoryFiles.swift:30-34`; `docs/library-keyboard.md:84` | Aşama 1 |
| 2 | Orta | Link önizleme resmi build'de varsayılan açık; kopyalama anında URL'ye GET + `og:image` hostuna ikinci GET. Tek kullanımlık/magic-login linkleri tüketilebilir. Gizli parametre filtresi yalnız tam ad eşleşmesi; path'teki token'lar geçer. Doküman "isteğe bağlı" diyor. Community build bunu kapalı derler. | `LinkMetadataService.swift:12,131-132`; `LinkHistory.swift:6`; `PublicLinkNetwork.swift:73-77`; `build-community.sh:35-39` | Aşama 0'da kapalı kalır |
| 3 | Orta | Aynı görsel her kopyada yeni `Clipboard <UUID>.png` olarak yazılır; dedup yalnız yol bazlı. #1 ile birleşince disk sınırsız büyür. | `ClipboardWatcher.swift:144`; `LibraryStore.swift:449` | Aşama 1 |
| 4 | Orta | Ana thread'de ağır iş: 0.5 sn timer'da 40 MP'e kadar TIFF→PNG; `@MainActor` `LibraryStore` her yazımda `BEGIN IMMEDIATE` + `synchronous=FULL`. OCR/embedding worker kilit tutarken UI 3 sn'ye kadar donabilir, sonra yakalama sessizce düşer. | `ClipboardWatcher.swift:69-70,135-140`; `LibraryStore.swift:218-219`; `LibraryDatabase.swift:32,85-89`; `LibraryImageSearch.swift:~77` | Sonra |
| 5 | Orta | Library açılamazsa uygulama kurtarma moduna geçer (yakalama durur), onarım/dışa aktarma yolu yok. | `AppDelegate.swift:30-34` | Sonra |
| 6 | Düşük | Şifre yöneticisi işaret listesi kısa (TypeIt4Me, KeeWeb, "Pasteboard generator type" eksik); uygulama bazlı hariç tutma yok. Kontrolün kendisi doğru (payload okunmadan önce). | `ClipboardWatcher.swift:48-51` | Sonra |
| 7 | Düşük | PNG'ler `.atomic` yazılıp sonra `0600` yapılıyor; kısa süre varsayılan izinle duruyor. | `ClipboardWatcher.swift:148-149` | Sonra |
| 8 | Düşük | Community build ad-hoc imzalı, hardened runtime yok; her yeniden derlemede Erişilebilirlik izni kaybolur. | `build-community.sh:122-127` | Aşama 0 (kalıcı yerel sertifika) |

## Sağlam olanlar

- **Ağ çıkışı tam listesi:** link metadata + küçük görseller, YouTube oEmbed / `*.ytimg.com`, github.com üzerinden Sparkle feed, eski GitHub API updater (yalnız resmi build), build sırasında hash'e sabitlenmiş model indirme (isteğe bağlı). Telemetri, analytics, crash raporlama yok.
- **Link getirme:** yalnız HTTPS:443, URL'de kimlik bilgisi yok, her DNS cevabı public olmalı ve doğrulanmış IP'ye bağlanılır, yönlendirme başına yeniden kontrol (en fazla 3), cookie yok, HTML çalıştırılmaz (`PublicLinkNetwork.swift`).
- **Doğrudan yapıştırma:** yalnız yakalanan uygulamaya (`postToPid`), şifre alanlarını reddeder, odak tekrar tekrar doğrulanır (`DirectPasteCoordinator.swift:196-260,302-308`).
- **Kısayollar:** `RegisterEventHotKey`; keylogging event tap yok.
- **Dosyalar:** klasörler 0700, dosyalar 0600, `O_NOFOLLOW`, symlink kontrolü.
- **SQL:** her yerde parametreli; şema idempotent; daha yeni şema sürümü açılmaz.
- **CI:** tüm action'lar first-party ve SHA'ya sabit; secret veya `pull_request_target` yok. Tek Swift bağımlılığı Sparkle 2.10.0 (revizyona sabit).
- **Electron (Windows):** `contextIsolation` + `sandbox`, `nodeIntegration` kapalı, IPC ana frame kontrolü, CSP `connect-src 'none'`.

## Resmi release paketi (REA + codesign)

- Zip ve `appcast.xml` hash'leri `SHA256SUMS` ve GitHub digest'leriyle eşleşiyor. Appcast EdDSA imzalı, feed `clipboardline-desktop` (eski ad, aynı repoya yönleniyor).
- İmza: kendinden imzalı `CN=ClipboardLine Review Local Signing` (SHA-1 `1488fcce…`). Developer ID, Team ID, notarization, hardened runtime, sandbox yok; Gatekeeper reddediyor. README bunu açıkça söylüyor.
- Paket: Sparkle 2.10.0, credential broker (hash'leri `credential-broker-config.json` ile birebir), `ClipboardLineUpdateInstaller` helper, MobileCLIP-S2 (194 MB). Analytics SDK, beklenmeyen dylib/betik, sızmış anahtar yok. `__MACOSX/` ve geliştirici notları paket artığı.
- **Köken boşluğu:** pakete damgalanan `ClipboardLineForkRevision=fb003f5f…` GitHub'da yok (HTTP 422). Binary'nin public koddan derlendiği doğrulanamadı. Binary'deki tüm URL'ler kaynakta mevcut. Fork kendi derlediği için bu bizi etkilemiyor.
- REA burada zayıftı: Swift kaynak/paket karşılaştırması yok, extraction symlink'leri atlıyor, string araması Ghidra/Hopper istiyor. Asıl doğrulama `codesign`, `spctl`, `strings` ile yapıldı.

## Proje sağlığı

- Geçmiş 2026-10-20'de başlıyor (squash'lanmış public snapshot). 8 günde 71 commit, 4 Mac + 4 Windows sürümü. 62 commit "ClipBoardLine contributors" kimliğiyle, dallar `codex/...`; kod büyük ölçüde AI ile üretilmiş, tek kişi merge ediyor.
- Churn çoğunlukla Windows UI kabul testlerinde; Mac çekirdeği kararlı.
- Upstream ileride geçmişi yeniden yazarsa (yeni squash) merge zorlaşır. Tendedero ile ortak git geçmişi yok.

## Fork'ta atılabilecek / kalması gereken

- **Çalışma zamanı dışı, fork için gereksiz:** `windows/`, `contracts/` parity raporları ve `scripts/check-*-parity.py`, `check-release-version.py`, `.coderabbit.yaml`, `.mergify.yml`, review automation, `credential-broker-config.json`, `Sources/UpdateCredentialBroker`, `Tests/CredentialBrokerIntegration`, `upstream-state.json`, eski `docs/parity-*`.
- **Kalmalı:** `Sources/Tendedero`, `Resources/*.lproj`, `scripts/build-community.sh`, `TendederoTests` + `ImageHistoryTests`, `scripts/check-strings.swift`, Sparkle pini.
- Merge kolaylığı için silmek yerine devre dışı bırakmak tercih edilir (bkz. `PLAN.md`).
