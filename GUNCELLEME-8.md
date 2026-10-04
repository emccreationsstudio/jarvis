# Jarvis — Güncelleme 8

Bu klasör Güncelleme 7'nin tamamı + yeni değişikliklerdir. GitHub'daki `jarvis` deposuna **olduğu gibi** yükleyebilirsin (aynı adlı dosyaların üzerine yazılır).

## Neler değişti

### Listeler
- **"+" düğmesi düzeltildi.** Artık her zaman tepki veriyor: alan boşken basınca yazma alanını açar, doluyken ekler ve klavye açık kalır (art arda ekleyebilirsin).
- **Dokun = işaretle, silmez.** Alışveriş, Aranacak ve kendi listelerinde dokununca üstü çizilir; tekrar dokununca geri açılır. Görevlerde dokununca biter, "Bugün tamamlananlar" bölümünde kalır.
- **Sola kaydır = çöp kutusu.** Silinen her şey (görev, ürün, arama, hafıza kaydı, liste) **30 gün** çöp kutusunda kalır. Silince altta 5 saniyelik **"Geri al"** şeridi çıkar. Listeler sekmesinin sağ üstündeki çöp simgesinden de geri alabilirsin.
- **Kendi listelerin.** "Yeni liste" ile Eczane, Günlük ilaçlar, Hediye fikirleri… istediğin kadar liste aç. **Günlük liste** seçersen işaretler her sabah kalkar (ilaçlar için ideal).
- **Sesle de:** "Eczane diye bir liste aç", "Günlük ilaç listeme D vitamini ekle", "İlaçlarımı içtim", "Eczane listesinden kremi çıkar".
- Görev düzenleme: sağa kaydır ya da basılı tut → Düzenle. "+1 sa / Yarın / +1 hafta" erteleme kısayolları eklendi.

### Konuşma
- **Sohbet gün boyu ekranda kalır**, her yeni günde sayfa temiz açılır (eski konuşmalar silinmez, Jarvis bugünün konuşmasını dikkate alır).
- **"Jarvis kapan" → yalnızca "Kapanıyorum" der.** Söylediğin iş varsa yine yapılır, cevap ekranda kalır ama uzun uzun okunmaz.
- "Kapat" / "Kapan" tek başına söylenirse kapanır; **"ışığı kapat", "alarmı kapat" gibi cümleler artık Jarvis'i kapatmıyor.**
- **Sayılar her zaman rakamla:** "yarın saat dörtte iki domates" → "yarın saat 4'te 2 domates", "yüzde elli" → "%50", "saat on dört otuz" → "saat 14.30". "Bir şey", "ona söyle", "otobüse bin", "yemek yedi" gibi sayı olmayanlara dokunmaz.
- **Daha iyi tanıma:** Apple'ın sunucudaki Türkçe tanıması kullanılıyor (cihazdakinden belirgin şekilde doğru; internet yoksa kendiliğinden cihaza döner). Listelerdeki ad ve ürünler, aranacak kişiler tanımaya ipucu olarak veriliyor. Ayrıca sunucu, yanlış duyulan sözcükleri bağlamdan düzeltiyor. Ayarlar → Ses → "Gelişmiş konuşma tanıma" ile kapatılabilir.

### Takvim
- Takvim sekmesinde **etkinliğe dokun → düzenle, ertele (+1 saat / yarın / +1 hafta), sil.** Göreve dokununca görev düzenleme açılır.
- **Sesle:** "Yarınki toplantıyı 15:00'e al", "Dişçiyi cumaya ertele", "Cuma akşamki yemeği iptal et".
- Jarvis artık önümüzdeki 7 günün takvimini görüyor (önceden 3).

### Harita, mesaj, arama
- **"Kadıköy'e yol tarifi başlat" → harita doğrudan açılır.** Ayarlar → Harita'dan Apple / Google / Yandex Navigasyon seçebilirsin.
- **"Ahmet'e toplantıdayım, sonra arayacağım yaz"** → Mesajlar (ya da "WhatsApp'tan" dersen WhatsApp) hazır metinle açılır, sen gönder'e basarsın.
- **"Annemi ara", "112'yi ara"** → hemen arar (iPhone onay sorar).

### Hava durumu ve sabah özeti
- Jarvis artık **hava durumunu biliyor** (bulunduğun yer; konum izni yoksa İstanbul) ve takvimine bağlıyor: dışarıda toplantı + yağmur → şemsiye ve trafik payı, soğuk → mont, kayıt günü soğuk/kuru → boğazı koruma.
- **Sabah özeti:** Ayarlar → Sabah özeti → aç ve saati seç. Her sabah bildirim gelir; dokununca Jarvis havayı, bugünkü planını ve **Türkiye'den 3, dünyadan 2 önemli haberi** okur. "Günaydın" ya da "haberler ne" demen de yeterli.
  Haber kaynakları: NTV, Anadolu Ajansı, BBC Türkçe, BBC World (başlıklar alınır, özeti Jarvis yapar).

### Bilgisayar uygulaması
- Telefonla eşitlemede yeni listeler, çöp kutusu ve işaretler **kaybolmaz**. Bilgisayarda da yeni listeler görünür, dokununca işaretlenir; sayılar rakamla yazılır, "Jarvis kapan" → "Kapanıyorum".

## Kurulum (3 adım)

1. **Sunucu (Cloudflare):** Worker → Edit code → `server/worker.js` içeriğini yapıştır → Deploy. Yeni bir anahtar ya da ayar gerekmiyor (hava durumu ve haberler ücretsiz kaynaklardan).
2. **GitHub:** Bu klasörün içindekileri `jarvis` deposuna yükle → Commit.
3. **Codemagic:** Start new build → Jarvis — TestFlight. Kurulunca Ayarlar → Konum iznini ver (hava durumu için), istersen Sabah özeti'ni aç.

Derlemede kırmızı bir adım olursa son satırlarını bana gönder, hemen düzeltirim.

## iPhone'un izin vermedikleri (bilerek yapılmadı)

- **Arayanı sesli duyurmak / meşgulken otomatik cevap:** Apple, uygulamaların gelen aramayı görmesine izin vermiyor. iPhone'un kendi özellikleri var: Ayarlar → Uygulamalar → Telefon → *Aramaları Seslendir* ve *Mesajla Yanıtla*. Jarvis'in Ayarlar → Aramalar bölümünde anlatılıyor.
- **Sağlık (Health) verileri:** Ayrı bir adım gerekiyor: developer.apple.com'da JARVISMobile kimliğine *HealthKit* yetkisi eklenip imza profili yenilenmeli. Bunu yapmadan eklersem derleme imzada kırılır. Hazır olduğunda söyle, bir sonraki güncellemede ekleyelim.

## Test listesi (telefonda)

- [ ] Alışveriş'te boş alana "+" → klavye açılıyor; ürün yazıp "+" → ekleniyor
- [ ] Ürüne dokun → üstü çiziliyor; tekrar dokun → geri geliyor
- [ ] Sola kaydırıp sil → "Geri al" şeridi; çöp kutusundan geri alma
- [ ] "Yeni liste" → Günlük ilaçlar; ertesi sabah işaretler kalkmış mı
- [ ] "Eczane listesine parol ekle" (sesle) → liste açılıp ürün ekleniyor
- [ ] "Yarın saat dörtte iki ekmek al hatırlat" → görev "2 ekmek", 16:00
- [ ] "Jarvis kapan" → yalnızca "Kapanıyorum"
- [ ] Takvimde etkinliğe dokun → saati değiştir → telefon takviminde de değişmiş
- [ ] "Taksim'e yol tarifi başlat" → harita açılıyor
- [ ] "Günaydın" → hava + plan + haberler
