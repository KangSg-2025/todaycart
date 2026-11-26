// 식품안전나라 「바코드연계제품정보」(C005) → 바코드 끝 3자리로 나눈 작은 파일 1,000개.
//
// 실행:
//   dart run tools/fetch_barcodes.dart [출력폴더] [--full]     (기본 출력: build/barcodes)
//
// 두 가지 방식 (API 제한 때문에):
//   · 처음(파일이 없을 때) 또는 --full : 전체 약 26만 건을 1,000건씩 약 260번.
//       날짜 조건 없이 부르면 「1시간에 100번」까지라 95번마다 1시간 쉬며 받음 → 약 3시간.
//   · 그다음부터(매주) : 최근 7일 바뀐 것만(CHNG_DT) 받아 기존 파일에 합침. 몇 번이면 끝.
//       (CHNG_DT 는 「호출일 기준 최대 7일」까지만 됨 → 매주 돌려야 빠짐없음)
//   · 이 키는 한 번에 한 요청만 받음(「현재 접속 중인 인증키」) → 하나씩 차례로.
//
// 인증키: 환경변수 FOOD_SAFETY_KOREA_KEY (GitHub Actions Secrets) 또는 api_keys.json.
// 키는 화면·파일에 절대 쓰지 않는다.
//
// 만드는 파일:
//   000.json … 999.json   {"8805522061018":["좋은상품 유기농 부침가루","사조동아원"], …}
//   version.json          {"updated":"2026-11-26","count":180000,"full":"2026-11-26"}
//
// 앱은 찍은 바코드의 끝 3자리 파일 하나(압축 전송 약 4KB)만 받는다.
// → 홈페이지 서버는 끝 3자리만 알 뿐, 무슨 상품을 찍었는지 모름.
import 'dart:convert';
import 'dart:io';

const _base = 'https://openapi.foodsafetykorea.go.kr/api';
const _page = 1000;

/// 날짜 조건 없이 1시간에 부를 수 있는 횟수 (API 한도 100 — 여유 5)
const _perHour = 95;

late final String _key;

/// 시험용 쪽 수 제한 (0 = 전체)
var _maxPages = 0;

Future<void> main(List<String> args) async {
  _key = _loadKey();
  final outDir = args.firstWhere(
    (a) => !a.startsWith('--'),
    orElse: () => 'build/barcodes',
  );
  final versionFile = File('$outDir/version.json');
  // 마지막 갱신이 7일 넘게 지났으면(PC를 오래 안 켬) 「최근 7일」로는 빠지는 게 생김 → 전체 다시
  var stale = false;
  if (versionFile.existsSync()) {
    final last = DateTime.tryParse(
      '${(jsonDecode(versionFile.readAsStringSync()) as Map)['updated']}',
    );
    stale = last == null || DateTime.now().difference(last).inDays > 7;
    if (stale) stdout.writeln('마지막 갱신이 오래돼서 전체를 다시 받아요 (약 3시간)');
  }
  final full = args.contains('--full') || !versionFile.existsSync() || stale;
  // 낮(6~19시)에는 키당 하루 300번까지라 전체(약 260번)는 저녁에만
  final hour = DateTime.now().hour;
  if (full && hour >= 6 && hour < 19 && !args.contains('--allow-day')) {
    stdout.writeln('낮(6~19시)에는 하루 300번 제한 — 바코드 전체 받기는 저녁 7시 이후에 해요. 이번엔 건너뜀.');
    return;
  }
  // 시험용: --pages=3 이면 앞의 3쪽(3,000건)만
  _maxPages = int.tryParse(
        args.where((a) => a.startsWith('--pages=')).map((a) => a.substring(8)).firstOrNull ?? '',
      ) ??
      0;

  // 바코드 → [이름, 제조사, 순위(고를 때만)]
  final best = <String, List<String>>{};
  if (!full) _loadShards(outDir, best);

  final ok = full ? await _fetchAll(best) : await _fetchRecent(best);
  if (!ok) exit(1);
  _writeShards(outDir, best, full, versionFile);
}

/// 처음: 전체 받기 (1시간 95번씩 쉬어 가며)
Future<bool> _fetchAll(Map<String, List<String>> best) async {
  var first = await _rows(1, 1);
  // 시작하자마자 시간 한도(같은 키를 다른 곳에서 막 썼을 때)면 1시간 쉬고 다시
  for (var i = 0; i < 2 && first.code == 'INFO-320'; i++) {
    stdout.writeln('  시간 한도 — 1시간 쉬고 시작해요');
    await Future<void>.delayed(const Duration(minutes: 61));
    first = await _rows(1, 1);
  }
  if (first.total <= 0) {
    stderr.writeln('전체 건수를 받지 못했어요: ${first.msg}');
    return false;
  }
  var pages = (first.total + _page - 1) ~/ _page;
  if (_maxPages > 0 && _maxPages < pages) pages = _maxPages;

  // 받은 쪽은 PC에 모아 둠 → 한도에 걸려 중간에 멈춰도 다음 실행 때 남은 쪽만 받음
  final progress = _Progress(first.total);
  final done = progress.load(best);
  stdout.writeln(
    '전체 받기: ${first.total}건 · $pages번 호출 (1시간에 $_perHour번씩)'
    '${done.isEmpty ? '' : ' · 이미 받은 ${done.length}쪽은 건너뜀'}',
  );

  var calls = 1;
  var hourStart = DateTime.now();
  final codes = <String, int>{};
  var dailyLimit = false;

  /// 한 쪽 받기. 받았으면 true
  Future<bool> fetchPage(int p) async {
    if (calls >= _perHour) {
      final wait = const Duration(minutes: 61) - DateTime.now().difference(hourStart);
      if (wait > Duration.zero) {
        stdout.writeln('  한도 쉬는 중 ${wait.inMinutes}분… (${done.length} / $pages)');
        await Future<void>.delayed(wait);
      }
      calls = 0;
      hourStart = DateTime.now();
    }
    var r = await _rows(p * _page + 1, (p + 1) * _page);
    calls++;
    if (r.code == 'INFO-320') {
      // 시간 한도에 걸림 → 1시간 쉬고 같은 쪽 다시
      stdout.writeln('  시간 한도 — 1시간 쉼 (${done.length} / $pages)');
      await Future<void>.delayed(const Duration(minutes: 61));
      calls = 0;
      hourStart = DateTime.now();
      r = await _rows(p * _page + 1, (p + 1) * _page);
      calls++;
    }
    if (r.rows.isEmpty) {
      codes[r.code] = (codes[r.code] ?? 0) + 1;
      // INFO-300: 하루 호출 수를 다 씀 → 오늘은 더 불러도 소용없음
      if (r.code == 'INFO-300') dailyLimit = true;
      return false;
    }
    _merge(best, r.rows);
    progress.save(p, r.rows);
    done.add(p);
    return true;
  }

  final failed = <int>[];
  for (var p = 0; p < pages && !dailyLimit; p++) {
    if (done.contains(p)) continue;
    if (!await fetchPage(p)) failed.add(p);
    if ((p + 1) % 20 == 0 || p + 1 == pages) stdout.writeln('  ${p + 1} / $pages');
  }
  // 실패한 쪽은 끝에서 한 번 더
  if (failed.isNotEmpty && !dailyLimit) {
    stdout.writeln('  실패한 ${failed.length}쪽 다시 받는 중…');
    for (final p in [...failed]) {
      if (dailyLimit) break;
      if (await fetchPage(p)) failed.remove(p);
    }
  }

  final missing = [for (var p = 0; p < pages; p++) if (!done.contains(p)) p];
  if (codes.isNotEmpty) {
    // 왜 실패했는지 기록에 남김 (INFO-300 하루 한도 · INFO-320 시간 한도 · FAIL 응답 없음 …)
    stdout.writeln('  실패 이유: ${codes.entries.map((e) => '${e.key} ${e.value}번').join(' · ')}');
  }
  if (missing.isNotEmpty) {
    stdout.writeln(
      '  아직 ${missing.length}쪽 남음${dailyLimit ? ' (하루 한도)' : ''} — '
      '받은 ${done.length}쪽은 저장해 뒀고, 다음 실행 때 남은 쪽만 받아요. 홈페이지 파일은 아직 안 바꿔요.',
    );
    return false;
  }
  progress.clear();
  return true;
}

/// 전체 받기 중간 저장: %USERPROFILE%\.todaycart\barcode_progress\ (저장소 밖, 키 없음)
/// - 쪽마다 p000.json … (그 쪽에서 쓸 값만)
/// - 전체 건수가 바뀌었거나 3일 넘게 지난 것은 버리고 처음부터
class _Progress {
  _Progress(this.total)
      : dir = Directory(
          '${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.'}'
          '/.todaycart/barcode_progress',
        );

  final int total;
  final Directory dir;

  File get _meta => File('${dir.path}/meta.json');
  File _pageFile(int p) => File('${dir.path}/p${p.toString().padLeft(3, '0')}.json');

  /// 저장해 둔 쪽을 [best]에 합치고, 받은 쪽 번호를 돌려줌
  Set<int> load(Map<String, List<String>> best) {
    final done = <int>{};
    try {
      if (!_meta.existsSync()) return done;
      final m = jsonDecode(_meta.readAsStringSync()) as Map;
      final started = DateTime.tryParse('${m['started']}');
      if (m['total'] != total || started == null ||
          DateTime.now().difference(started).inDays > 3) {
        clear();
        return done;
      }
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        final mm = RegExp(r'^p(\d{3})\.json$').firstMatch(name);
        if (mm == null) continue;
        final rows = (jsonDecode(f.readAsStringSync()) as List)
            .map((r) => (r as Map).cast<String, Object?>())
            .toList();
        _merge(best, rows);
        done.add(int.parse(mm.group(1)!));
      }
    } catch (_) {
      // 깨진 중간 파일이면 처음부터
      clear();
      done.clear();
      best.clear();
    }
    return done;
  }

  void save(int p, List<Map<String, Object?>> rows) {
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      if (!_meta.existsSync()) {
        _meta.writeAsStringSync(jsonEncode({
          'total': total,
          'started': DateTime.now().toIso8601String(),
        }));
      }
      // 쓰는 칸만 남겨 작게
      final slim = [
        for (final r in rows)
          {
            'BAR_CD': r['BAR_CD'],
            'PRDLST_NM': r['PRDLST_NM'],
            'BSSH_NM': r['BSSH_NM'],
            'CLSBIZ_DT': r['CLSBIZ_DT'],
            'PRMS_DT': r['PRMS_DT'],
          },
      ];
      _pageFile(p).writeAsStringSync(jsonEncode(slim));
    } catch (_) {}
  }

  void clear() {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// 매주: 최근 7일 바뀐 것만 받아 합치기
Future<bool> _fetchRecent(Map<String, List<String>> best) async {
  final since = DateTime.now().subtract(const Duration(days: 6));
  final d = '${since.year}${_p2(since.month)}${_p2(since.day)}';
  final first = await _rows(1, _page, chng: d);
  if (first.code != 'INFO-000' && first.code != 'INFO-200') {
    stderr.writeln('최근 바뀐 자료를 받지 못했어요: ${first.msg}');
    return false;
  }
  final pages = first.total <= 0 ? 0 : (first.total + _page - 1) ~/ _page;
  stdout.writeln('최근 바뀐 것($d 이후): ${first.total}건 · $pages번 호출');
  _merge(best, first.rows);
  for (var p = 1; p < pages; p++) {
    _merge(best, (await _rows(p * _page + 1, (p + 1) * _page, chng: d)).rows);
  }
  return true;
}

void _merge(Map<String, List<String>> best, List<Map<String, Object?>> rows) {
  for (final row in rows) {
    final code = (row['BAR_CD'] ?? '').toString().trim();
    final name = _cleanName((row['PRDLST_NM'] ?? '').toString());
    if (!RegExp(r'^\d{8,14}$').hasMatch(code) || name.isEmpty) continue;
    final maker = _cleanMaker((row['BSSH_NM'] ?? '').toString());
    final closed = (row['CLSBIZ_DT'] ?? '').toString().isNotEmpty;
    final date = (row['PRMS_DT'] ?? '').toString();
    // 같은 바코드가 여러 줄이면: 폐업 안 한 곳 · 최근 허가 쪽
    final rank = '${closed ? 0 : 1}$date';
    final old = best[code];
    if (old == null || rank.compareTo(old[2]) >= 0) {
      best[code] = [name, maker, rank];
    }
  }
}

/// 기존 파일 읽기 (주간 갱신용). 순위는 모르니 '0'으로 → 새로 받은 것이 이김
void _loadShards(String outDir, Map<String, List<String>> best) {
  for (var i = 0; i < 1000; i++) {
    final f = File('$outDir/${i.toString().padLeft(3, '0')}.json');
    if (!f.existsSync()) continue;
    final m = jsonDecode(f.readAsStringSync()) as Map;
    for (final e in m.entries) {
      final v = (e.value as List).map((x) => x.toString()).toList();
      best[e.key.toString()] = [v.first, v.length > 1 ? v[1] : '', '0'];
    }
  }
}

void _writeShards(
  String outDir,
  Map<String, List<String>> best,
  bool full,
  File versionFile,
) {
  final shards = <String, Map<String, List<String>>>{};
  for (final e in best.entries) {
    final k = e.key.substring(e.key.length - 3);
    (shards[k] ??= {})[e.key] = [
      e.value[0],
      if (e.value[1].isNotEmpty) e.value[1],
    ];
  }
  Directory(outDir).createSync(recursive: true);
  var bytes = 0, gz = 0;
  for (var i = 0; i < 1000; i++) {
    final k = i.toString().padLeft(3, '0');
    final m = shards[k] ?? const <String, List<String>>{};
    final sorted = Map.fromEntries(
      m.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    final json = jsonEncode(sorted);
    File('$outDir/$k.json').writeAsStringSync(json);
    final b = utf8.encode(json);
    bytes += b.length;
    gz += gzip.encode(b).length;
  }
  final now = DateTime.now();
  final today = '${now.year}-${_p2(now.month)}-${_p2(now.day)}';
  var fullDay = today;
  if (!full && versionFile.existsSync()) {
    fullDay = ((jsonDecode(versionFile.readAsStringSync()) as Map)['full'] ?? today)
        .toString();
  }
  versionFile.writeAsStringSync(jsonEncode({
    'updated': today,
    'full': fullDay,
    'count': best.length,
    'source': '식품안전나라 바코드연계제품정보',
  }));
  stdout.writeln(
    '완료: 바코드 ${best.length}개 · 파일 1,000개 · 전체 ${(bytes / 1048576).toStringAsFixed(1)}MB'
    ' · 한 개 평균 ${(bytes / 1000 / 1024).toStringAsFixed(1)}KB'
    ' (압축 ${(gz / 1000 / 1024).toStringAsFixed(1)}KB)',
  );
}

String _p2(int v) => v.toString().padLeft(2, '0');

/// 「좋은상품 유기농 부침가루」 — 앞뒤 공백 · 겹친 공백 정리
String _cleanName(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// 「사조동아원(주) 부산공장」 → 「사조동아원」
String _cleanMaker(String s) => s
    .replaceAll(RegExp(r'\(주\)|㈜|주식회사|\(유\)|유한회사|농업회사법인|영농조합법인'), '')
    .replaceAll(RegExp(r'\s*\S*(공장|지점|사업장)$'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

class _Page {
  const _Page(this.total, this.rows, this.code, this.msg);
  final int total;
  final List<Map<String, Object?>> rows;

  /// INFO-000 정상 · INFO-200 없음 · INFO-320 시간 한도 · INFO-500 동시 접속 …
  final String code;
  final String msg;
}

Future<_Page> _rows(int start, int end, {String? chng}) async {
  final url = '$_base/$_key/C005/json/$start/$end'
      '${chng == null ? '' : '/CHNG_DT=$chng'}';
  for (var attempt = 1; attempt <= 6; attempt++) {
    final body = await _get(url);
    try {
      final c = (jsonDecode(body) as Map)['C005'] as Map;
      final result = (c['RESULT'] as Map?) ?? const {};
      final code = (result['CODE'] ?? '').toString();
      // 동시 접속(INFO-500)이면 잠깐 쉬었다가 다시
      if (code == 'INFO-500') {
        await Future<void>.delayed(Duration(seconds: attempt * 3));
        continue;
      }
      return _Page(
        int.tryParse('${c['total_count']}') ?? 0,
        [
          for (final r in (c['row'] as List? ?? const []))
            (r as Map).cast<String, Object?>(),
        ],
        code,
        (result['MSG'] ?? '').toString(),
      );
    } catch (_) {
      await Future<void>.delayed(Duration(seconds: attempt * 3));
    }
  }
  stdout.writeln('  실패: ${url.replaceAll(_key, '<key>').split('/C005/').last}');
  return const _Page(0, [], 'FAIL', '응답 없음');
}

String _loadKey() {
  final env = Platform.environment['FOOD_SAFETY_KOREA_KEY'];
  if (env != null && env.isNotEmpty) return env;
  final f = File('api_keys.json');
  if (f.existsSync()) {
    final k = (jsonDecode(f.readAsStringSync()) as Map)['FOOD_SAFETY_KOREA_KEY'];
    if (k is String && k.isNotEmpty) return k;
  }
  stderr.writeln('FOOD_SAFETY_KOREA_KEY 가 없어요 (환경변수 또는 api_keys.json).');
  exit(1);
}

final _client = HttpClient()..connectionTimeout = const Duration(seconds: 30);

Future<String> _get(String url) async {
  try {
    final req = await _client.getUrl(Uri.parse(url));
    final res = await req.close().timeout(const Duration(seconds: 90));
    return await res.transform(utf8.decoder).join();
  } catch (e) {
    return '';
  }
}
