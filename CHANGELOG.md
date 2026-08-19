# Changelog

## 0.1.0

Rasmiy `posthog_flutter` (v5.36.2) plaginining sof Dart qayta
implementatsiyasi. Asosiy maqsad — **Windows va Linux'ni qo'llab-quvvatlash**:
rasmiy plagin native SDK'larga tayangani uchun bu platformalarda jimgina
no-op'ga aylanardi.

### Qo'shildi

- Sof Dart HTTP transporti: `/batch`, `/s/`, `/flags/?v=2`, remote config.
- Diskdagi navbat: bitta fayl = bitta event, UUIDv7 nomlash bilan tartib
  kafolati. Offline'da eventlar saqlanadi va tarmoq qaytgach yuboriladi.
- Eksponensial retry backoff (1s → 30s) jitter bilan, `Retry-After`
  sarlavhasini hisobga oladi.
- Shaxs boshqaruvi: anonim ID, `distinct_id`, `$anon_distinct_id` orqali
  birlashtirish, bootstrap.
- Sessiya boshqaruvi: 30 daqiqa faoliyatsizlik va 24 soat maksimal davomiylik
  qoidalari; fonda aylantirish o'rniga tozalash.
- Platformaga xos kontekst property'lari, shu jumladan **Windows va Linux**
  uchun (`$os_name`, `$device_type`, ekran o'lchamlari).
- Feature bayroqlari: yuklash, diskda cache, offline'da oxirgi ma'lum
  qiymatlar, `$feature_flag_called` dedup bilan.
- Session replay: rrweb `$snapshot` eventini Dart'da qurish, PNG → JPEG qayta
  kodlash, sessiya boshida bir marta sampling.
- Surveys: remote config'dan yuklash, targeting shartlarini Dart'da baholash,
  branching (`end`, `specific_question`, `response_based`), `survey shown` /
  `survey sent` / `survey dismissed` eventlari.

### Tuzatildi

- Survey modelida savol `id` maydoni xato ravishda `type` dan o'qilardi — bu
  `$survey_response_<id>` kalitlarini buzardi va bir xil turdagi savollar
  bir-birini bosardi.
- Survey branching (`end`, `specific_question`, `response_based`) endi
  qo'llab-quvvatlanadi. Rasmiy plaginda bu qaror native SDK'da qabul
  qilinardi (`surveyAction` MethodChannel chaqiruvi), web'da esa umuman
  ishlamasdi.
- Survey payload'ini tahlil qilishdagi non-null cast'lar to'liqsiz ma'lumotda
  crash berardi; endi default qiymatlarga tushadi.
- Stack trace filtrida paket nomi qattiq yozilgan edi (`posthog_flutter`), shu
  sababli SDK o'z frame'larini tanimay qolardi.

### O'zgartirildi (rasmiy plagindan farqlar)

- `beforeSend` endi **barcha** eventlarga qo'llanadi. Rasmiy SDK'da native
  tomondan yuborilgan eventlar undan o'tmasdi.
- Uzoq offline holatda navbat tashlab yuborilmaydi. Rasmiy SDK 3 marta
  muvaffaqiyatsizlikdan keyin `dropAllRecords()` chaqirib butun navbatni
  o'chirardi.
- `Duration` sozlamalari sub-soniyali aniqlikni saqlaydi (native API butun
  sonli soniyalarni kutgani uchun ular 1s ga yaxlitlanardi).

### Qo'llab-quvvatlanmaydi

Native SDK'ni talab qiladigan imkoniyatlar API mosligi uchun no-op sifatida
saqlangan: push notification metodlari, `pushIdentityProvider`,
`captureNativeScreens`, `captureNativeExceptions`. Batafsil — README.
