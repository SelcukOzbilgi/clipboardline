# Fork planı

## Kararlar (Efe, 2026-10-28)

- Fork: `SelcukOzbilgi/clipboardline` (public, parent `orkunisitmak/clipboardline` @ `00452eb`, 1.7.8).
- Görünen ad **ClipBoardLine** kalır ("Dev", "EFE" gibi ek yok).
- Kalıcı yerel imza sertifikası: her yeniden derlemede Erişilebilirlik izni yeniden istenmesin.
- Upstream güncelleme kanalı ve credential broker fork'ta asla çalışmaz.
- Hedef yalnız macOS (arm64).

## Kimlik değerleri

| Alan | Resmi upstream | Upstream community build | Bu fork |
|---|---|---|---|
| Görünen ad / `.app` | ClipBoardLine | ClipBoardLine Dev | ClipBoardLine |
| Bundle ID | `local.clipboardline.review` | `org.clipboardline.community` | `io.github.selcukozbilgi.clipboardline` |
| Veri klasörü | `~/Library/Application Support/Tendedero/Screenshots` | `…/ClipBoardLine Dev/Screenshots` | `…/ClipBoardLine/Screenshots` |
| Kurtarma defaults suite | `local.clipboardline.recovery` | `org.clipboardline.community.recovery` | `io.github.selcukozbilgi.clipboardline.recovery` |
| Güncelleme | Sparkle + GitHub API updater | kapalı (bundle ID kapısı) | kapalı (bundle ID kapısı + test) |
| Link önizleme varsayılanı | açık | kapalı | kapalı |
| İmza | kendinden imzalı resmi sertifika | ad-hoc | yerelde kalıcı kendinden imzalı sertifika; CI'da ad-hoc |

Bu Mac'te resmi uygulama ve `Tendedero` veri klasörü yok (2026-10-28 kontrol edildi).

## Yaklaşım: küçük, eklemeli değişiklik

- `scripts/build-community.sh` ortam değişkenleriyle parametrelenir (ad, bundle ID, veri klasörü, suite, sürüm, imza kimliği); varsayılanlar upstream'deki değerlerle aynı kalır. Fork değerleri ince bir `scripts/build-fork.sh` sarmalayıcısında durur. Böylece upstream merge'lerinde çakışma tek dosyada ve küçük olur.
- Güncelleme kodu ve `windows/` silinmez: güncelleme yolları resmi bundle ID dışında zaten reddediyor (`PublicUpdateChannel.swift:19`, `AppUpdateController.swift:352`). Bu davranışı fork bundle ID'siyle bir test korur. Silmek her upstream merge'inde `AppDelegate` gibi büyük dosyalarda çakışma üretir.
- Kendi başına duran ve hiçbir yerden referans alınmayan credential broker kaynakları (`Sources/UpdateCredentialBroker`, `credential-broker-config.json`, `Tests/CredentialBrokerIntegration`) silinebilir; Package.swift'te zaten hedef değiller.
- Fork'ta anlamsız repo otomasyonu dosya silinmeden kapatılır: `gh workflow disable` (Pages, Windows). Mergify/CodeRabbit uygulamaları kurulu olmadığı için dosyaları etkisiz.

## Aşamalar

### Aşama 0: fork hijyeni + indirilebilir Mac build
1. `build-community.sh` parametreleme + `scripts/build-fork.sh`; sürüm `release-version.json`'dan, build numarası git commit sayısından.
2. Kalıcı yerel imza: login keychain'de `ClipBoardLine Local Signing (SelcukOzbilgi)` kod imzalama sertifikası. Özel anahtar repoya veya başka bir yere kopyalanmaz.
3. Güncelleme kanalının fork bundle ID'siyle kapalı kaldığını doğrulayan test.
4. CI: `macos.yml` fork build'ini alır, `ClipBoardLine-macos-arm64.zip` artifact'ı yükler; Windows'a bağlı adımlar (`--require-windows`, parity) fork'ta atlanır. `efe-v*` etiketinde release.
5. `AGENTS.md` fork kurallarıyla yeniden yazılır (CLAUDE.md'yi işaret eder).
6. Testler + localization kontrolü; PR yalnız fork'a, merge Efe'nin kararı.

### Aşama 1: gerçek silme ve disk büyümesi
1. Çöp Kutusu'ndaki kayıtlar N gün (varsayılan 30) sonra kalıcı silinir: `items` satırı + FTS/analiz satırları, uygulamaya ait dosyalar; ardından `VACUUM`/WAL checkpoint. Elle "Çöp'ü boşalt" komutu.
2. `Library/Backups` budama.
3. Görsel kopyalarında içerik hash'iyle dedup.
4. Testler: purge, dosya temizliği, sabitlenmiş/klasördeki öğelerin korunması.

#### Aşama 1 durumu: kalıcı silme tamam (`efe/faz-1`)

1, 2 ve 4. maddeler bitti; 3. madde (görsel dedup) açık.

- **Otomatik purge:** Çöp Kutusu'nda 30 günden uzun duran kayıtlar (`deleted`, `LibraryStore.trashPurgeDays`) açılışta ve saatlik zamanlayıcıda kalıcı silinir. Saklama süresi ayarından bağımsızdır. `deletedAt` olmayan kayda dokunulmaz.
- **Korunan kayıtlar:** açık "Çöp'e taşı" sabitlemeyi, klasör ve etiket üyeliğini silmiyor; metin dedup'ı da eski kopyayı bunlarla birlikte Çöp'e atıyor. Sabitlenmiş (`favorite`) ya da bir klasörde/etikette olan kayıtları otomatik purge atlar; yalnız "Çöp Kutusu'nu boşalt" siler. Yalnız "Kütüphaneye kaydet" (`retained`) koruma sayılmaz.
- **Çöp Kutusu'nu boşalt:** ⌘K Eylemler paleti ve Kütüphane → Çöp görünümündeki çubuk. Onay penceresi sayıyı gösterir; o anda alınan listeden yalnız hâlâ Çöp'te olanlar silinir (arada geri yüklenen kalır).
- **Ne silinir:** `items` satırı ve `search_fts`, `text_identity`, `image_analysis`, `item_tags`, `item_collections`, `image_markup_garbage` kayıtları. Dosyalar Finder Çöp'üne değil doğrudan diskten silinir: inbox'taki `Clipboard <UUID>.png`, `Favorites/Favorite <UUID>.*` (sabitleme kopyası, markup tabanı/çıktısı, kayıt orijinali), `Library/Thumbnails/<id>-*.image`, sürükle/dışa aktar için yazılan `Texts/Text <id>.txt` ve `Links/Link <id>.webloc`. Harici orijinallere (`originalPath`, izlenen klasörler, symlink) dokunulmaz; başka bir kaydın hâlâ kullandığı yol silinmez. Dosya listesi aynı transaction'da `purged_files` tablosuna yazılır, yarıda kalırsa açılışta tamamlanır.
- **Veritabanında kopya bırakmama:** her bağlantıda `PRAGMA secure_delete=ON`. Silme olduktan sonra arka planda FTS `optimize` + `VACUUM` + `wal_checkpoint(TRUNCATE)`; bekleyen iş `metadata` bayrağıyla bir sonraki purge'de ya da açılışta yeniden dener.
- **Yedekler:** `Library/Backups/Before-Library-<UUID>` klasörleri 30 günden eskiyse store açıldıktan sonra silinir.
- **Geri alma:** purge edilen kayıtlar Çöp ve askı geri alma günlüklerinden düşer.
- Testler: `Tests/ImageHistoryTests/TrashPurgeTests.swift`.

### Sonra (öncelik sırası belirsiz)
- Ana thread'den görsel kodlama ve SQLite yazımını almak (REVIEW #4).
- Şifre yöneticisi işaret listesini genişletmek, uygulama bazlı hariç tutma (REVIEW #6).
- Kurtarma modunda dışa aktarma/onarım (REVIEW #5).

## Komutlar

```sh
# Bir kerelik: kalıcı yerel imza sertifikası (login keychain parolasını sorar)
bash scripts/fork-signing-setup.sh

# Derleme (sertifika varsa onunla, yoksa ad-hoc imzalar)
bash scripts/build-fork.sh
open build/ClipBoardLine.app

# Testler (Command Line Tools'ta XCTest yok)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
swift scripts/check-strings.swift

# Upstream'den güncelleme
git fetch upstream && git merge upstream/main
```

`swift run` ve paketlenmemiş binary kullanılmaz: resmi `Tendedero` veri klasörüne yazar (`Inbox.swift:39`).
