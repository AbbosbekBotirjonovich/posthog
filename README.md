# posthog

[![pub package](https://img.shields.io/pub/v/posthog.svg)](https://pub.dev/packages/posthog)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[PostHog](https://posthog.com) uchun sof Dart SDK — **Windows, Linux, Android,
iOS, macOS va Web'da bir xil ishlaydi**.

Rasmiy [`posthog_flutter`](https://pub.dev/packages/posthog_flutter) plagini
`posthog-android` va `posthog-ios` native SDK'lari ustidagi qobiq. Windows va
Linux uchun native SDK mavjud emas, shuning uchun u yerda plagin **jimgina
no-op'ga aylanadi**: ilova xatosiz ishlaydi, lekin hech qanday analitika
yig'ilmaydi. Bu paket o'sha ishni sof Dart'da, to'g'ridan-to'g'ri PostHog HTTP
API'si orqali bajaradi — native bog'liqliksiz.

API rasmiy plagin bilan aynan mos, shuning uchun **migratsiya import qatorini
almashtirishdan iborat**.

## Platformalar

| Imkoniyat | Android | iOS | macOS | Web | **Windows** | **Linux** |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Event capture, identify, groups | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Feature flags | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Error tracking (Dart) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Session replay | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| Surveys | ✅ | ✅ | ✅ | —¹ | ✅ | ✅ |
| Offline navbat (diskda) | ✅ | ✅ | ✅ | —² | ✅ | ✅ |

¹ Web'da PostHog JS SDK'sidan foydalaning — `surveys` sozlamasi e'tiborsiz
qoldiriladi.  ² Web'da navbat xotirada; batafsil [quyida](#malumot-saqlanishi).

Rasmiy plagin bilan taqqoslaganda:

| | `posthog_flutter` | `posthog` |
|---|---|---|
| Windows / Linux | ❌ jimgina no-op | ✅ to'liq |
| Native crash (fatal) | ✅ | ❌ |
| Push notification | ✅ | ❌ |

Qo'llab-quvvatlanmaydigan imkoniyatlar API mosligi uchun no-op sifatida
saqlangan — mavjud kod kompilyatsiya bo'ladi. Batafsil:
[Cheklovlar](#cheklovlar).

## O'rnatish

```yaml
dependencies:
  posthog: ^0.1.0
```

## Boshlash

```dart
import 'package:flutter/material.dart';
import 'package:posthog/posthog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = PostHogConfig('<loyiha_api_kaliti>')
    ..host = 'https://us.i.posthog.com'
    ..captureApplicationLifecycleEvents = true;

  await Posthog().setup(config);

  runApp(const MyApp());
}
```

API kalitini PostHog'da **Project settings → Project API key** dan oling. EU
mintaqasi uchun `host` ni `https://eu.i.posthog.com` qiling; o'zingiz hosting
qilsangiz — o'z domeningizni.

Ekran ko'rishlarini avtomatik yig'ish uchun `PosthogObserver` ni ulang (surveys
uchun ham shu talab qilinadi):

```dart
MaterialApp(
  navigatorObservers: [PosthogObserver()],
  home: const HomePage(),
);
```

Session replay uchun ilovani `PostHogWidget` bilan o'rang:

```dart
PostHogWidget(
  child: MaterialApp(...),
);
```

## Ishlatish

### Eventlar

```dart
await Posthog().capture(
  eventName: 'buyurtma_yakunlandi',
  properties: {'summa': 42.5, 'valyuta': 'UZS'},
);

await Posthog().screen(screenName: 'Savat');
```

### Foydalanuvchi shaxsi

```dart
await Posthog().identify(
  userId: 'user-123',
  userProperties: {'plan': 'pro'},
);

await Posthog().group(groupType: 'company', groupKey: 'acme');

// Chiqishda — keyingi eventlar yangi anonim shaxsga bog'lanadi.
await Posthog().reset();
```

### Feature flags

```dart
if (await Posthog().isFeatureEnabled('yangi_dizayn')) {
  // ...
}

final variant = await Posthog().getFeatureFlag('tugma_rangi');
final result = await Posthog().getFeatureFlagResult('yangi_dizayn');

await Posthog().reloadFeatureFlags();
```

Bayroqlar diskda cache qilinadi, shuning uchun offline'da oxirgi ma'lum
qiymatlar qaytadi.

### Xatolar va loglar

```dart
try {
  await riskyOperation();
} catch (e, s) {
  await Posthog().captureException(error: e, stackTrace: s);
}

Posthog().logger.info('foydalanuvchi kirdi', {'usul': 'google'});
Posthog().logger.error('to\'lov muvaffaqiyatsiz', {'kod': 'E001'});
```

Tutilmagan Dart xatolarini avtomatik yig'ish uchun:

```dart
final config = PostHogConfig('<kalit>')
  ..errorTrackingConfig.captureFlutterErrors = true
  ..errorTrackingConfig.capturePlatformDispatcherErrors = true
  ..errorTrackingConfig.captureIsolateErrors = true;
```

### Super properties

```dart
await Posthog().register('ilova_bosqichi', 'beta'); // har eventga qo'shiladi
await Posthog().unregister('ilova_bosqichi');
```

### Maxfiylik

```dart
await Posthog().disable();  // yig'ishni to'xtatish
await Posthog().enable();
```

Boshidanoq o'chirish uchun `config.optOut = true`.

Session replay'da maxfiy maydonlarni yashirish:

```dart
PostHogMaskWidget(
  child: Text('Karta raqami: 4111 1111 1111 1111'),
);
```

## Konfiguratsiya

```dart
final config = PostHogConfig('<kalit>')
  ..host = 'https://us.i.posthog.com'
  ..flushAt = 20
  ..flushInterval = const Duration(seconds: 30)
  ..sessionReplay = true
  ..debug = true;
```

| Sozlama | Default | Tavsif |
|---|---|---|
| `host` | `https://us.i.posthog.com` | API manzili (EU yoki self-hosted) |
| `flushAt` | `20` | Shuncha event yig'ilganda yuboriladi |
| `flushInterval` | `30s` | Vaqt bo'yicha yuborish oralig'i |
| `maxQueueSize` | `1000` | Navbat chegarasi; oshsa eng eski o'chiriladi |
| `maxBatchSize` | `50` | Bitta so'rovdagi maksimal event |
| `captureApplicationLifecycleEvents` | `true` | `Application Opened` va h.k. |
| `preloadFeatureFlags` | `true` | `setup()` da bayroqlarni yuklash |
| `sendFeatureFlagEvents` | `true` | `$feature_flag_called` yuborish |
| `sessionReplay` | `false` | Session replay |
| `surveys` | `true` | Surveys (web'da e'tiborsiz) |
| `personProfiles` | `identifiedOnly` | Anonim eventlar uchun profil yaratish |
| `optOut` | `false` | Yig'ishni boshidanoq o'chirish |
| `debug` | `false` | Konsolga batafsil log |

Eventni yuborishdan oldin o'zgartirish yoki tashlab yuborish:

```dart
config.beforeSend = [
  (event) => event.event == '\$screen' ? null : event, // tashlanadi
];
```

## Rasmiy plagindan o'tish

Metod nomlari, parametr nomlari va default qiymatlar **aynan bir xil**.
Import qatorini almashtiring:

```dart
// eski
import 'package:posthog_flutter/posthog_flutter.dart';

// yangi
import 'package:posthog/posthog.dart';
```

`pubspec.yaml` da:

```yaml
dependencies:
  # posthog_flutter: ^5.36.2
  posthog: ^0.1.0
```

Boshqa hech nima o'zgarmaydi. Native tomon (Android `AndroidManifest.xml`,
iOS `Info.plist`) sozlamalari endi kerak emas — ularni olib tashlashingiz
mumkin.

Diqqat: bu paket alohida `distinct_id` va navbat saqlaydi. Migratsiyadan keyin
mavjud foydalanuvchilarga yangi anonim ID beriladi; uzluksizlik kerak bo'lsa
`config.bootstrap` orqali eski qiymatni bering.

## Cheklovlar

Quyidagilar native SDK'ni talab qiladi va sof Dart'da amalga oshirib
bo'lmaydi. API mosligi uchun ular **no-op** sifatida saqlangan — mavjud kod
kompilyatsiya bo'ladi, lekin hech nima yuborilmaydi:

- `registerPushNotificationToken()`, `unregisterPushNotificationToken()`,
  `capturePushNotificationOpened()` — FCM/APNs token registratsiyasi
- `PostHogConfig.pushIdentityProvider`
- `PostHogSessionReplayConfig.captureNativeScreens` — Flutter UI'sini qoplagan
  native ekranni suratga olish
- `PostHogErrorTrackingConfig.captureNativeExceptions` — native fatal crash

Shuningdek:

- **Exception steps** buferi Dart'da yashaydi, shuning uchun native fatal
  crash'dan omon qolmaydi (rasmiy plaginda u native SDK'da edi).
- **Web'da navbat xotirada**: sahifa yangilanganda yuborilmagan eventlar
  yo'qoladi. Foydalanuvchi shaxsi esa `localStorage` da saqlanadi.
- **Native platform view'lar** replay'da qora maska bilan qoplanadi (ularni
  suratga olish native SDK'ni talab qiladi).

## Rasmiy plagindan farqlar

Windows va Linux qo'llab-quvvatlashidan tashqari:

- `beforeSend` **barcha** eventlarga qo'llanadi. Rasmiy SDK'da native tomondan
  yuborilgan eventlar (`survey shown` va boshqalar) undan o'tmasdi.
- Retry backoff'ga **jitter** qo'shildi — ko'p qurilma offline'dan bir vaqtda
  qaytganda serverga to'lqin hosil qilmaydi.
- Uzoq offline holatda **navbat tashlab yuborilmaydi**. Rasmiy SDK 3 marta
  muvaffaqiyatsizlikdan keyin butun navbatni o'chirardi.
- Survey modelidagi **bug tuzatildi**: savol `id` maydoni xato ravishda `type`
  dan o'qilardi, bu javob kalitlarini buzardi.
- Survey **branching** (`end`, `specific_question`, `response_based`) endi
  ishlaydi. Rasmiy plaginda bu qaror native SDK'da qabul qilinardi, web'da esa
  umuman qo'llab-quvvatlanmasdi.
- Survey payload'ini tahlil qilish **crash bermaydi**: to'liqsiz ma'lumot
  default qiymatlarga tushadi.
- `Duration` sozlamalari sub-soniyali aniqlikni saqlaydi (native API butun
  soniyalarni kutgani uchun ular yaxlitlanardi).

Kodda har bir ataylab qilingan chetlanish `// PostHog upstream'dan farq:`
izohi bilan belgilangan.

## Ma'lumot saqlanishi

| Platforma | Navbat | Shaxs va sozlamalar |
|---|---|---|
| Windows | `%APPDATA%/posthog/` | `%APPDATA%/posthog/state.json` |
| Linux / macOS | application support katalogi | o'sha katalogda `state.json` |
| Android / iOS | application support katalogi | o'sha katalogda `state.json` |
| Web | xotira | `localStorage` |

Navbat: bitta fayl = bitta event, nomi UUIDv7. Bu tartibni kafolatlaydi va
yozish paytida jarayon o'lsa faqat oxirgi, chala yozilgan event yo'qoladi.

Yuborish muvaffaqiyatsiz bo'lsa eksponensial backoff qo'llanadi (1s → 30s,
jitter bilan), `Retry-After` sarlavhasi hisobga olinadi. 4xx javoblar qayta
urinilmaydi; tarmoq xatolari va 5xx — urinilaveradi.

## Namuna

`example/` katalogida Windows, Linux, macOS, Android, iOS va Web'da
ishlaydigan to'liq ilova bor:

```bash
cd example
flutter run -d windows --dart-define=POSTHOG_KEY=phc_xxx
```

## Litsenziya

MIT. Bu paket rasmiy
[`posthog-flutter`](https://github.com/PostHog/posthog-flutter) plaginining
Dart kodiga asoslangan (MIT, © PostHog). To'liq atribut — [LICENSE](LICENSE).

Bu jamoatchilik tomonidan yaratilgan paket va PostHog Inc. bilan rasmiy
aloqasi yo'q.
