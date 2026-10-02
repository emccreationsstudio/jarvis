# Jarvis — Kurulum (1. aşama)

Üç parça var:
1. **Sunucu (beyin):** Cloudflare'de ücretsiz çalışır, OpenAI anahtarınız orada güvenle durur.
2. **iPhone uygulaması:** Codemagic derler, TestFlight'tan telefona kurarsınız.
3. **Telefondaki ayar:** Uygulamaya sunucu adresini ve şifreyi girersiniz.

---

## 1. Sunucu — Cloudflare Worker (≈10 dk)

1. **dash.cloudflare.com** adresinde ücretsiz hesap açın.
2. Sol menüden **Compute (Workers)** → **Workers & Pages** → **Create** → **Start with Hello World** → ad: `jarvis` → **Deploy**.
3. **Edit code**'a basın. Soldaki `worker.js` dosyasının içini tamamen silin, bu projedeki `server/worker.js` dosyasının içeriğini yapıştırın → sağ üstte **Deploy**.
4. Worker sayfasında **Settings → Variables and Secrets → Add**:
   - `OPENAI_API_KEY` · tür **Secret** · değer: OpenAI anahtarınız
   - `APP_TOKEN` · tür **Secret** · değer: uzun bir şifre (örnek: `P78a5iYKG5RIInCeG7WMGSYqsnk8q4CN`)
   - (İsteğe bağlı) `OPENAI_MODEL` · tür **Text** · varsayılan `gpt-5.6-luna`
   → **Deploy**.
5. Worker'ın adresini kopyalayın (ör. `https://jarvis.KULLANICI.workers.dev`). Tarayıcıda açınca `{"status":"online","name":"Jarvis"}` görmelisiniz.

> Eski bilgisayar sunucusundaki `.env` dosyasında OpenAI anahtarınız yazılı. O anahtar hiçbir yerde paylaşılmadıysa aynen kullanabilirsiniz; emin değilseniz OpenAI panelinden yeni anahtar oluşturun.

## 2. GitHub

- github.com → **New repository** → ad `jarvis` → **Private** → Create.
- Bu klasörün **içindekileri** (codemagic.yaml, project.yml, Jarvis, server…) depoya yükleyin ve Commit changes deyin.
- GitHub → Settings → Applications → **Codemagic → Configure** → `jarvis` deposuna da erişim verin.

## 3. Apple

`com.emccreationsstudio.JARVISMobile` kimliği zaten kayıtlı.
1. **developer.apple.com → Profiles → +** → **App Store Connect** → App ID: **JARVISMobile** → sertifika: Codemagic'in oluşturduğu (2027/10/01) → ad `Jarvis App Store` → Generate.
2. **appstoreconnect.apple.com → Apps → + New App** → iOS · ad: benzersiz bir ad (ör. `Jarvis Kişisel Asistan`; sonra değiştirilebilir) · dil Turkish · Bundle ID: **JARVISMobile** · SKU `jarvis001`.

## 4. Codemagic

1. **Settings → Code signing identities → iOS provisioning profiles → Fetch profiles** → `Jarvis App Store` → referans `jarvis_appstore` → Download.
2. **Applications → Add application → GitHub → jarvis** → tür: **Other** (ayar dosyası `codemagic.yaml`).
3. **Start new build** → workflow **Jarvis — TestFlight**.

Kırmızı bir adım olursa o adımın kaydının son satırlarını Claude'a gönderin.

## 5. iPhone

1. TestFlight'tan Jarvis'i kurun ve açın → **İzinleri ver ve başla**.
2. **Ayarlar** sekmesi → sunucu adresi + `APP_TOKEN` şifresi → **Bağlantıyı test et**.
3. **Siri:** "Hey Siri, Jarvis" → açılır ve dinler. "Hey Siri, Jarvis'e söyle" → söylediğinizi iletir.
4. **Arkaya Dokunma:** Ayarlar → Erişilebilirlik → Dokunma → Arkaya Dokunma → Çift Dokunma → **Jarvis'i Dinlet**.

## Önem sırası nasıl çalışıyor

| Önem | Ne olur |
|---|---|
| Kritik | iOS 26'da **alarm gibi çalar** (sessiz modda bile) + 30 dk önce ön bildirim |
| Yüksek | Sesli bildirim + 5 ve 10 dakika sonra tekrar |
| Normal | Sesli bildirim |
| Düşük | Sessiz bildirim |

Bildirimdeki **Tamamlandı** ve **10 dk ertele** düğmeleri doğrudan çalışır.
