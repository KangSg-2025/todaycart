// 한국소비자원 참가격(생필품 가격) → 앱이 받을 작은 요약 파일 만들기.
//
// 실행:
//   dart run tools/fetch_prices.dart [출력폴더] [--day=YYYYMMDD]
//   (기본 출력: build/prices)
//
// 인증키: 환경변수 DATA_GO_KR_KEY (GitHub Actions Secrets) 또는 api_keys.json 의 DATA_GO_KR_KEY.
// 키는 화면·파일에 절대 쓰지 않는다.
//
// 만드는 파일:
//   version.json            {"day":"20261106","count":604}
//   latest.json             최신 조사 요약 (상품별 최저·평균·최고 · 체인별 평균)
//   history/<day>.json      조사일마다 같은 내용 (가격 추이용)
//
// API 메모 (2026-11-26 실제 호출로 확인):
//   getProductInfoSvc.do        전체 상품 (약 604개)
//   getStoreInfoSvc.do          전체 판매점 (약 627곳)
//   getProductPriceInfoSvc      ← .do 없음. goodInspectDay(금요일) + goodId 필수
//   조사는 2주마다 금요일. 일일 트래픽 기능마다 2,000건.
import 'dart:convert';
import 'dart:io';

const _base = 'https://apis.data.go.kr/B551919/ProductPriceInfoService';

late final String _key;

Future<void> main(List<String> args) async {
  _key = _loadKey();
  final outDir = args.firstWhere((a) => !a.startsWith('--'), orElse: () => 'build/prices');
  final forcedDay = args
      .where((a) => a.startsWith('--day='))
      .map((a) => a.substring(6))
      .firstOrNull;

  stdout.writeln('상품 · 판매점 목록 받는 중…');
  final products = _items(await _get('getProductInfoSvc.do'), 'item');
  final stores = _items(
    await _get('getStoreInfoSvc.do'),
    'iros.openapi.service.vo.entpInfoVO',
  );
  final storeName = {for (final s in stores) s['entpId']!: s['entpName'] ?? ''};
  stdout.writeln('  상품 ${products.length}개 · 판매점 ${stores.length}곳');

  final day = forcedDay ?? await _latestDay(products);
  if (day == null) {
    stderr.writeln('최근 조사일을 찾지 못했어요.');
    exit(1);
  }

  // 이미 만든 조사일이면 건너뜀 (Actions에서 매주 돌려도 2주에 한 번만 갱신)
  final versionFile = File('$outDir/version.json');
  if (forcedDay == null && versionFile.existsSync()) {
    final old = jsonDecode(versionFile.readAsStringSync()) as Map;
    if (old['day'] == day) {
      stdout.writeln('이미 최신 ($day) — 할 일 없음');
      return;
    }
  }
  stdout.writeln('조사일 $day 가격 받는 중… (상품 ${products.length}번 호출)');

  final out = <Map<String, Object?>>[];
  var done = 0;
  // 동시에 4개씩
  for (var i = 0; i < products.length; i += 4) {
    final batch = products.skip(i).take(4).toList();
    final results = await Future.wait(batch.map((p) async {
      final rows = _items(
        await _get(
          'getProductPriceInfoSvc',
          'goodInspectDay=$day&goodId=${p['goodId']}',
        ),
        'iros.openapi.service.vo.goodPriceVO',
      );
      return _summarize(p, rows, storeName);
    }));
    for (final r in results) {
      if (r != null) out.add(r);
    }
    done += batch.length;
    if (done % 100 < 4) stdout.writeln('  $done / ${products.length}');
  }
  out.sort((a, b) => (a['n'] as String).compareTo(b['n'] as String));

  final summary = {
    'day': day,
    'source': '한국소비자원 참가격',
    'count': out.length,
    'items': out,
  };
  final json = jsonEncode(summary);
  Directory('$outDir/history').createSync(recursive: true);
  File('$outDir/latest.json').writeAsStringSync(json);
  File('$outDir/history/$day.json').writeAsStringSync(json);
  versionFile.writeAsStringSync(jsonEncode({'day': day, 'count': out.length}));
  final kb = (utf8.encode(json).length / 1024).toStringAsFixed(1);
  final gz = (gzip.encode(utf8.encode(json)).length / 1024).toStringAsFixed(1);
  stdout.writeln('완료: 가격 있는 상품 ${out.length}개 · latest.json $kb KB (압축 $gz KB)');
}

/// 판매점 이름 → 체인 (앱에서 「이마트 평균」처럼 보여 줌)
String chainOf(String name) {
  final n = name.replaceAll(' ', '');
  if (RegExp(r'^(GS25|CU|세븐일레븐|이마트24|미니스톱)').hasMatch(n)) return '편의점';
  if (n.startsWith('이마트')) return '이마트';
  if (n.startsWith('롯데슈퍼')) return '롯데슈퍼';
  if (n.startsWith('GS더프레시')) return 'GS더프레시';
  if (n.contains('농협') || n.contains('하나로')) return '하나로마트';
  if (n.startsWith('현대백화점')) return '현대백화점';
  if (n.startsWith('신세계')) return '신세계백화점';
  if (n.startsWith('홈플러스')) return '홈플러스';
  if (n.startsWith('롯데마트')) return '롯데마트';
  return '기타';
}

int _round10(num v) => ((v / 10).round() * 10);

Map<String, Object?>? _summarize(
  Map<String, String> product,
  List<Map<String, String>> rows,
  Map<String, String> storeName,
) {
  final prices = <int>[];
  final byChain = <String, List<int>>{};
  for (final r in rows) {
    final p = int.tryParse(r['goodPrice'] ?? '');
    if (p == null || p <= 0) continue;
    prices.add(p);
    final c = chainOf(storeName[r['entpId']] ?? '');
    (byChain[c] ??= []).add(p);
  }
  if (prices.isEmpty) return null;
  prices.sort();
  final avg = prices.reduce((a, b) => a + b) / prices.length;
  return {
    'id': int.tryParse(product['goodId'] ?? '') ?? 0,
    'n': (product['goodName'] ?? '').trim(),
    'min': prices.first,
    'avg': _round10(avg),
    'max': prices.last,
    'k': prices.length, // 조사한 판매점 수
    'c': {
      for (final e in byChain.entries)
        if (e.key != '기타')
          e.key: _round10(e.value.reduce((a, b) => a + b) / e.value.length),
    },
  };
}

/// 최근 금요일부터 거슬러 올라가며 가격이 있는 조사일 찾기
Future<String?> _latestDay(List<Map<String, String>> products) async {
  final probe = products.isEmpty ? '35' : products.first['goodId']!;
  var d = DateTime.now();
  while (d.weekday != DateTime.friday) {
    d = d.subtract(const Duration(days: 1));
  }
  for (var i = 0; i < 6; i++) {
    final day = '${d.year}${_pad2(d.month)}${_pad2(d.day)}';
    // 상품 하나로는 빠질 수 있어 두 개로 확인
    for (final id in {probe, '35'}) {
      final rows = _items(
        await _get('getProductPriceInfoSvc', 'goodInspectDay=$day&goodId=$id'),
        'iros.openapi.service.vo.goodPriceVO',
      );
      if (rows.isNotEmpty) return day;
    }
    d = d.subtract(const Duration(days: 7));
  }
  return null;
}

String _pad2(int v) => v.toString().padLeft(2, '0');

String _loadKey() {
  final env = Platform.environment['DATA_GO_KR_KEY'];
  if (env != null && env.isNotEmpty) return env;
  final f = File('api_keys.json');
  if (f.existsSync()) {
    final k = (jsonDecode(f.readAsStringSync()) as Map)['DATA_GO_KR_KEY'];
    if (k is String && k.isNotEmpty) return k;
  }
  stderr.writeln('DATA_GO_KR_KEY 가 없어요 (환경변수 또는 api_keys.json).');
  exit(1);
}

final _client = HttpClient()..connectionTimeout = const Duration(seconds: 30);

Future<String> _get(String op, [String query = '']) async {
  final url = '$_base/$op?serviceKey=$_key${query.isEmpty ? '' : '&$query'}';
  for (var attempt = 1; ; attempt++) {
    try {
      final req = await _client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 60));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 200) return body;
      throw HttpException('HTTP ${res.statusCode}');
    } catch (e) {
      if (attempt >= 3) {
        // 키가 오류 글에 섞여 나오지 않게
        stderr.writeln('  실패 $op ${query.split('&').where((q) => !q.startsWith('serviceKey')).join('&')}: '
            '${e.toString().replaceAll(_key, '<key>')}');
        return '';
      }
      await Future<void>.delayed(Duration(seconds: attempt * 2));
    }
  }
}

/// 평평한 XML에서 `<tag>…</tag>` 묶음을 {이름: 값} 으로
List<Map<String, String>> _items(String xml, String tag) {
  final out = <Map<String, String>>[];
  final block = RegExp('<$tag>(.*?)</$tag>', dotAll: true);
  final field = RegExp(r'<(\w+)>([^<]*)</\1>');
  for (final m in block.allMatches(xml)) {
    out.add({
      for (final f in field.allMatches(m.group(1)!))
        f.group(1)!: _unescape(f.group(2)!),
    });
  }
  return out;
}

String _unescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');
