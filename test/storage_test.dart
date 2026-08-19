import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:posthog_dart/src/internal/posthog_preferences.dart';
import 'package:posthog_dart/src/internal/posthog_queue_storage.dart';
import 'package:posthog_dart/src/internal/posthog_uuid.dart';

/// Fayl tizimidagi saqlashni tekshiradi.
///
/// Bu qatlam ma'lumot yo'qolishining oldini oladi: offline holatda eventlar
/// diskda kutadi va ilova qayta ishga tushganda tiklanadi. Windows'da bu
/// `%APPDATA%` ostida ishlaydi.
void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    tempDir = await Directory.systemTemp.createTemp('posthog_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('navbatni diskda saqlash', () {
    PostHogQueueStorage buildStorage({String queueName = 'events'}) =>
        PostHogQueueStorage(projectToken: 'tok', queueName: queueName);

    test('round-trips an event through the file system', () async {
      final storage = buildStorage();
      final id = PostHogUuid.generate();

      await storage.persist(id, {'event': 'test', 'properties': {'a': 1}});
      final loaded = await storage.loadAll();

      expect(loaded.single.id, id);
      expect(loaded.single.event['event'], 'test');
      expect(loaded.single.event['properties'], {'a': 1});
    });

    test('survives a fresh storage instance', () async {
      final id = PostHogUuid.generate();
      await buildStorage().persist(id, {'event': 'saqlangan'});

      // Ilova qayta ishga tushgani kabi.
      final loaded = await buildStorage().loadAll();

      expect(loaded.single.event['event'], 'saqlangan');
    });

    // Fayl nomi UUIDv7 bo'lgani uchun leksikografik saralash = xronologik
    // tartib. Bu buzilsa eventlar PostHog'ga chalkash ketma-ketlikda ketardi.
    test('returns events in generation order', () async {
      final storage = buildStorage();
      final ids = <String>[];

      for (var i = 0; i < 20; i++) {
        final id = PostHogUuid.generate();
        ids.add(id);
        await storage.persist(id, {'event': 'e$i'});
      }

      final loaded = await storage.loadAll();

      expect(loaded.map((e) => e.id).toList(), ids);
      expect(
        loaded.map((e) => e.event['event']).toList(),
        [for (var i = 0; i < 20; i++) 'e$i'],
      );
    });

    test('removes only the requested events', () async {
      final storage = buildStorage();
      final keep = PostHogUuid.generate();
      final drop = PostHogUuid.generate();

      await storage.persist(keep, {'event': 'qoladi'});
      await storage.persist(drop, {'event': 'ketadi'});
      await storage.remove([drop]);

      final loaded = await storage.loadAll();
      expect(loaded.single.event['event'], 'qoladi');
    });

    test('clear() empties the queue directory', () async {
      final storage = buildStorage();
      await storage.persist(PostHogUuid.generate(), {'event': 'a'});

      await storage.clear();

      expect(await storage.loadAll(), isEmpty);
    });

    // Turli navbatlar (eventlar / replay) aralashmasligi kerak.
    test('keeps separate queues isolated', () async {
      final events = buildStorage(queueName: 'events');
      final replay = buildStorage(queueName: 'replay');

      await events.persist(PostHogUuid.generate(), {'event': 'oddiy'});
      await replay.persist(PostHogUuid.generate(), {'event': r'$snapshot'});

      expect((await events.loadAll()).single.event['event'], 'oddiy');
      expect((await replay.loadAll()).single.event['event'], r'$snapshot');
    });

    test('keeps separate projects isolated', () async {
      final a = PostHogQueueStorage(projectToken: 'proj-a', queueName: 'events');
      final b = PostHogQueueStorage(projectToken: 'proj-b', queueName: 'events');

      await a.persist(PostHogUuid.generate(), {'event': 'a-dan'});

      expect((await a.loadAll()).length, 1);
      expect(await b.loadAll(), isEmpty);
    });

    // Yozish paytida jarayon o'lsa chala fayl qolishi mumkin — u yuborilmasligi
    // va navbatni band qilib turmasligi kerak.
    test('discards a corrupted event file', () async {
      final storage = buildStorage();
      final good = PostHogUuid.generate();
      await storage.persist(good, {'event': 'yaxshi'});

      // Chala yozilgan faylni qo'lda yaratamiz.
      final dir = Directory('${tempDir.path}/posthog/tok/events');
      await File('${dir.path}/${PostHogUuid.generate()}.event')
          .writeAsString('{"event": "chala');

      final loaded = await storage.loadAll();

      expect(loaded.length, 1);
      expect(loaded.single.event['event'], 'yaxshi');
    });

    // `.tmp` fayllar oldingi ishga tushishdan qolgan chala yozuvlar.
    test('cleans up leftover temp files', () async {
      final storage = buildStorage();
      await storage.persist(PostHogUuid.generate(), {'event': 'a'});

      final dir = Directory('${tempDir.path}/posthog/tok/events');
      final leftover = File('${dir.path}/${PostHogUuid.generate()}.tmp');
      await leftover.writeAsString('chala yozuv');

      await storage.loadAll();

      expect(await leftover.exists(), isFalse);
    });

    test('handles a large backlog', () async {
      final storage = buildStorage();

      for (var i = 0; i < 200; i++) {
        await storage.persist(PostHogUuid.generate(), {'event': 'e$i'});
      }

      expect((await storage.loadAll()).length, 200);
    });
  });

  group('SDK holatini diskda saqlash', () {
    test('round-trips values through the file system', () async {
      final preferences = PostHogPreferences(projectToken: 'tok');
      await preferences.load();

      preferences.set('distinctId', 'user-1');
      preferences.set('count', 7);
      preferences.set('flag', true);
      await preferences.flush();

      final reloaded = PostHogPreferences(projectToken: 'tok');
      await reloaded.load();

      expect(reloaded.getString('distinctId'), 'user-1');
      expect(reloaded.getInt('count'), 7);
      expect(reloaded.getBool('flag'), isTrue);
    });

    test('round-trips nested maps', () async {
      final preferences = PostHogPreferences(projectToken: 'tok');
      await preferences.load();

      preferences.set('flags', {'beta': true, 'theme': 'dark'});
      await preferences.flush();

      final reloaded = PostHogPreferences(projectToken: 'tok');
      await reloaded.load();

      expect(reloaded.getMap('flags'), {'beta': true, 'theme': 'dark'});
    });

    test('keeps separate projects isolated', () async {
      final a = PostHogPreferences(projectToken: 'proj-a');
      await a.load();
      a.set('key', 'a-qiymat');
      await a.flush();

      final b = PostHogPreferences(projectToken: 'proj-b');
      await b.load();

      expect(b.getString('key'), isNull);
    });

    test('clear() wipes the stored state', () async {
      final preferences = PostHogPreferences(projectToken: 'tok');
      await preferences.load();
      preferences.set('key', 'value');
      await preferences.flush();

      await preferences.clear();

      final reloaded = PostHogPreferences(projectToken: 'tok');
      await reloaded.load();
      expect(reloaded.getString('key'), isNull);
    });

    // Buzilgan holat SDK'ni ishdan chiqarmasligi kerak — foydalanuvchi
    // identifikatori yo'qoladi, lekin ilova ishlashda davom etadi.
    test('starts empty when the stored state is corrupted', () async {
      final dir = Directory('${tempDir.path}/posthog/tok');
      await dir.create(recursive: true);
      await File('${dir.path}/state.json').writeAsString('{buzilgan json');

      final preferences = PostHogPreferences(projectToken: 'tok');
      await preferences.load();

      expect(preferences.getString('anything'), isNull);
      // Yozish hali ham ishlaydi.
      preferences.set('key', 'value');
      await preferences.flush();
      expect(preferences.getString('key'), 'value');
    });

    // Yozish paytida jarayon o'lsa eski holat buzilmasligi kerak.
    test('writes atomically via a temp file', () async {
      final preferences = PostHogPreferences(projectToken: 'tok');
      await preferences.load();
      preferences.set('key', 'value');
      await preferences.flush();

      final dir = Directory('${tempDir.path}/posthog/tok');
      final files = await dir.list().map((e) => e.path).toList();

      expect(files.where((f) => f.endsWith('state.json')).length, 1);
      expect(files.where((f) => f.endsWith('.tmp')), isEmpty);
    });

    test('persists a JSON-encodable snapshot of state', () async {
      final preferences = PostHogPreferences(projectToken: 'tok');
      await preferences.load();
      preferences.set('a', 'b');
      await preferences.flush();

      final content = await File(
        '${tempDir.path}/posthog/tok/state.json',
      ).readAsString();

      expect(jsonDecode(content), {'a': 'b'});
    });
  });
}
