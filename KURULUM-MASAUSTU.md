# Jarvis — Bilgisayar (Windows ve Mac) kurulumu

Bilgisayardaki Jarvis telefondakiyle aynı sunucuyu kullanır. Kurulum dosyalarını GitHub kendisi derler: Windows için `.exe`, Mac için `.dmg`.

## 1. Sunucuyu güncelle (Cloudflare)

1. Cloudflare → **Workers & Pages** → **jarvis** → **Edit code**.
2. Kodun hepsini silin, yeni `jarvis-worker.js` içeriğini yapıştırın → **Deploy**.
   Bu sürümle gelenler: bilgisayar için konuşmayı yazıya çevirme (`/stt`) ve eşitleme (`/sync`).

### Eşitleme istiyorsanız (isteğe bağlı)
1. Cloudflare sol menü → **Storage & databases** → **Workers KV** → **Create instance / Create namespace** → ad: `jarvis-data` → **Create**.
2. **Workers & Pages** → **jarvis** → **Settings** → **Bindings** → **+ Add binding** → **KV namespace**.
   - Variable name: `JARVIS_KV`
   - KV namespace: `jarvis-data`
   → **Add binding / Deploy**.
3. Telefonda **Ayarlar → Bilgisayarla eşitle** açın, bilgisayarda **Ayarlar → Telefonla eşitle** açın.

Eşitleme kapalıyken her cihaz kendi verisini tutar.

## 2. Kodu GitHub'a yükle

Zip'ten çıkan klasörün **içindeki** `Jarvis`, `desktop`, `server` ve `.github` klasörlerini GitHub'da **Add file → Upload files** sayfasına sürükleyin → **Commit changes**.

## 3. Kurulum dosyalarını derlet (GitHub Actions)

1. GitHub'da **jarvis** deposu → üstte **Actions** sekmesi.
   İlk seferde "Workflows aren't being run…" uyarısı çıkarsa **I understand my workflows, go ahead and enable them** düğmesine basın.
2. Soldan **Jarvis Masaüstü** → sağda **Run workflow** → **Run workflow**.
   (Bundan sonra `desktop` klasörüne her yüklemede kendiliğinden çalışır.)
3. 5–10 dakika sonra yeşil tik çıkar. Çalışmaya tıklayın → en altta **Artifacts**:
   - **Jarvis-Windows** → içinden `Jarvis-Kurulum-1.0.0.exe`
   - **Jarvis-Mac** → içinden `Jarvis-Mac.dmg`

## 4. Windows'a kur

1. `Jarvis-Windows.zip`'i açın → `Jarvis-Kurulum-1.0.0.exe`'ye çift tıklayın.
2. "Windows bilgisayarınızı korudu" uyarısı çıkarsa: **Ek bilgi → Yine de çalıştır**.
   (Uygulama imzalı olmadığı için bu uyarı normaldir; kendi uygulamanız.)
3. Kurulum bitince Jarvis açılır.

## 5. Mac'e kur

1. `Jarvis-Mac.dmg`'yi açın → **Jarvis**'i **Applications** klasörüne sürükleyin.
2. İlk açılışta: Applications'ta Jarvis'e **sağ tıklayın → Aç → Aç**.
3. "Jarvis hasarlı" derse Terminal'i açıp şunu yazın, sonra yeniden açın:
   ```
   xattr -cr /Applications/Jarvis.app
   ```
4. Mikrofon izni sorulduğunda **İzin ver**.

## 6. İlk ayar

1. **Ayarlar → Sunucu**: telefondaki adres ve şifrenin aynısı → **Bağlantıyı test et**.
2. İsterseniz **Bilgisayar açılınca başlat**'ı açın.

## Kullanım

- **Ctrl + Shift + J** (Mac: **⌘ + ⇧ + J**): Jarvis her yerden açılır ve "Efendim?" deyip dinler.
- Konuşun; susunca hepsini birlikte düşünüp cevaplar. **"Jarvis kapan"** ile kapanır. Yazarak da sorabilirsiniz.
- Pencereyi kapatınca Jarvis saatin yanındaki tepsi simgesinde çalışmaya ve hatırlatmaya devam eder. Tamamen çıkmak için simgeye sağ tıklayıp **Çık**.

## Telefondan farkları

- Bilgisayarda telefon takvimi okunmaz; "toplantı ekle" gibi istekler Jarvis takvimine zamanlı görev olarak eklenir. Eşitleme açıksa telefonda da görünür.
- Rota istekleri Google Haritalar'da güncel trafikle açılır.
- Aranacaklar listesi tutulur ama bilgisayardan arama yapılmaz.
