import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/database.dart';
import 'package:notes/data/notes_repository.dart';
import 'package:notes/data/plan_map_repository.dart';

/// 계획 지도: cards, arrows, progress, and copies of the page.
void main() {
  late NotesRepository repo;
  setUp(() async {
    final dir = Directory.systemTemp.createTempSync('plan_map');
    addTearDown(() => dir.deleteSync(recursive: true));
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    repo = NotesRepository(db, assetsDir: dir.path);
    await repo.init();
  });

  test('cards, arrows and what is still blocked', () async {
    final map = await repo.createPlanMap(title: '레드스톤 자동화 팜');
    expect((await repo.getPage(map))!.kind, planMapKind);
    final iron = await repo.addMapCard(map, x: 100, y: 100, title: '철 주괴');
    final wood = await repo.addMapCard(map, x: 300, y: 100, title: '나무');
    final hopper = await repo.addMapCard(map, x: 200, y: 300, title: '호퍼');
    await repo.addMapCard(map, x: 80, y: 40, title: '철 팜', label: true);
    var m = await repo.watchPlanMap(map).first;
    await repo.addMapEdge(map, m, iron, hopper);
    m = await repo.watchPlanMap(map).first;
    await repo.addMapEdge(map, m, wood, hopper);
    await repo.addMapEdge(map, m, iron, hopper); // repeat: ignored
    m = await repo.watchPlanMap(map).first;

    expect(m.edges.length, 2);
    expect(m.total, 3); // the title doesn't count
    expect(m.needs(hopper).map((c) => c.title).toSet(), {'철 주괴', '나무'});
    expect(m.blocked(m.card(hopper)!), isTrue);

    await repo.updateMapCard(map, m.card(iron)!, done: true);
    await repo.updateMapCard(map, m.card(wood)!, done: true, x: 320);
    m = await repo.watchPlanMap(map).first;
    expect(m.blocked(m.card(hopper)!), isFalse);
    expect(m.doneCount, 2);
    expect(m.card(wood)!.x, 320);

    // A picture on a card; the done flag stays.
    await repo.updateMapCard(map, m.card(wood)!, image: 'asset://pic');
    m = await repo.watchPlanMap(map).first;
    expect(m.card(wood)!.image, 'asset://pic');
    expect(m.card(wood)!.done, isTrue);

    // Memo and checklist; what can be done now.
    await repo.updateMapCard(
      map,
      m.card(hopper)!,
      note: '상자 5개 필요',
      checks: const [MapCheck('철 5개'), MapCheck('상자', done: true)],
    );
    m = await repo.watchPlanMap(map).first;
    expect(m.card(hopper)!.note, '상자 5개 필요');
    expect(m.card(hopper)!.checksDone, 1);
    expect(m.ready.map((c) => c.key), [hopper]); // iron, wood done

    // Search finds a card's text.
    expect((await repo.search('호퍼')).map((h) => h.page.id), contains(map));

    // Deleting a card takes its arrows along.
    await repo.deleteMapCard(map, m, m.card(iron)!);
    m = await repo.watchPlanMap(map).first;
    expect(m.edges.single.from, wood);
  });

  test('a copied map keeps its arrows', () async {
    final map = await repo.createPlanMap(title: '여행 준비');
    final a = await repo.addMapCard(map, x: 0, y: 0, title: '여권');
    final b = await repo.addMapCard(map, x: 0, y: 200, title: '출국');
    await repo.addMapEdge(map, await repo.watchPlanMap(map).first, a, b);
    final copy = await repo.duplicatePage(map);
    final m = await repo.watchPlanMap(copy).first;
    expect(m.cards.length, 2);
    expect(m.edges.length, 1);
    expect(m.card(m.edges.single.to)!.title, '출국');
  });
}
