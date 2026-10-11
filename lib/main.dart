
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const WeiboMonitorApp());
}

class WeiboMonitorApp extends StatelessWidget {
  const WeiboMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '微博更新提醒',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE6162D),
        ),
        useMaterial3: true,
      ),
      home: const MonitorPage(),
    );
  }
}

class MonitorPage extends StatefulWidget {
  const MonitorPage({super.key});

  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> {
  final uidController = TextEditingController();
  final intervalController = TextEditingController(text: '10');
  final cookieController = TextEditingController();

  Timer? timer;
  bool loading = false;
  String status = '请填写微博 UID，然后点击检查';
  String latestText = '';
  String latestId = '';
  String latestTime = '';
  String errorText = '';

  @override
  void initState() {
    super.initState();
    loadSettings();
  }

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    uidController.text = prefs.getString('uid') ?? '6342263193';
    intervalController.text =
        (prefs.getInt('interval') ?? 10).toString();
    cookieController.text = prefs.getString('cookie') ?? '';

    final savedId = prefs.getString('last_id') ?? '';
    latestId = savedId;
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final minutes = int.tryParse(intervalController.text) ?? 10;

    await prefs.setString('uid', uidController.text.trim());
    await prefs.setInt(
      'interval',
      minutes.clamp(1, 1440),
    );
    await prefs.setString('cookie', cookieController.text.trim());

    if (!mounted) return;
    setState(() => status = '设置已保存');
  }

  Future<Map<String, dynamic>> fetchLatest() async {
    final uid = uidController.text.trim();
    if (uid.isEmpty) {
      throw Exception('请填写微博 UID');
    }

    final uri = Uri.https(
      'm.weibo.cn',
      '/api/container/getIndex',
      {
        'containerid': '230413$uid',
        'page': '1',
        'count': '20',
      },
    );

    final headers = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) '
          'Version/17.0 Mobile/15E148 Safari/604.1',
      'Accept': 'application/json, text/plain, */*',
      'Referer': 'https://m.weibo.cn/',
    };

    final cookie = cookieController.text.trim();
    if (cookie.isNotEmpty) {
      headers['Cookie'] = cookie;
    }

    final response = await http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw Exception('微博接口返回 HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(
      utf8.decode(response.bodyBytes),
    ) as Map<String, dynamic>;

    if (decoded['ok'] != 1) {
      throw Exception('微博接口未返回正常数据，请检查 Cookie 或 UID');
    }

    final data = decoded['data'];
    final cards = data is Map ? data['cards'] : null;

    if (cards is! List) {
      throw Exception('没有找到微博列表');
    }

    final posts = <Map<String, dynamic>>[];

    void addCard(dynamic card) {
      if (card is! Map) return;
      final mblog = card['mblog'];
      if (mblog is Map && mblog['id'] != null) {
        posts.add(Map<String, dynamic>.from(mblog));
      }
    }

    for (final card in cards) {
      if (card is! Map) continue;

      if (card['card_type'] == 9) {
        addCard(card);
      } else if (card['card_type'] == 11) {
        final group = card['card_group'];
        if (group is List) {
          for (final item in group) {
            addCard(item);
          }
        }
      }
    }

    if (posts.isEmpty) {
      throw Exception('当前页面没有解析到微博，请稍后重试');
    }

    return posts.first;
  }

  String cleanText(dynamic value) {
    return (value ?? '')
        .toString()
        .replaceAll(
          RegExp(r'<br\s*/?>', caseSensitive: false),
          '\n',
        )
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .trim();
  }

  Future<void> checkWeibo() async {
    if (loading) return;

    setState(() {
      loading = true;
      status = '正在读取微博……';
      errorText = '';
    });

    try {
      await saveSettings();
      final post = await fetchLatest();

      final id = post['id']?.toString() ?? '';
      final text = cleanText(post['text']);
      final createdAt = post['created_at']?.toString() ?? '';

      final prefs = await SharedPreferences.getInstance();
      final previousId = prefs.getString('last_id') ?? '';

      if (previousId.isNotEmpty && previousId != id) {
        if (mounted) {
          setState(() {
            status = '发现微博更新！';
          });
        }
      } else {
        if (mounted) {
          setState(() {
            status = previousId.isEmpty
                ? '首次读取成功，已记录当前微博'
                : '检查完成，暂未发现更新';
          });
        }
      }

      await prefs.setString('last_id', id);

      if (!mounted) return;
      setState(() {
        latestId = id;
        latestText = text;
        latestTime = createdAt;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        status = '读取失败';
        errorText = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  void startMonitoring() {
    timer?.cancel();

    final minutes = int.tryParse(intervalController.text) ?? 10;
    final safeMinutes = minutes.clamp(1, 1440);

    timer = Timer.periodic(
      Duration(minutes: safeMinutes),
      (_) => checkWeibo(),
    );

    setState(() => status = '已开启轮询，间隔 $safeMinutes 分钟');
    checkWeibo();
  }

  void stopMonitoring() {
    timer?.cancel();
    timer = null;
    setState(() => status = '轮询已停止');
  }

  @override
  void dispose() {
    timer?.cancel();
    uidController.dispose();
    intervalController.dispose();
    cookieController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('微博更新提醒'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: uidController,
            decoration: const InputDecoration(
              labelText: '微博 UID',
              hintText: '例如 6342263193',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: intervalController,
            decoration: const InputDecoration(
              labelText: '检查间隔（分钟）',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: cookieController,
            decoration: const InputDecoration(
              labelText: '微博 Cookie（可选）',
              helperText: '接口返回 432 或读取失败时，可填入游客 Cookie',
              border: OutlineInputBorder(),
            ),
            minLines: 1,
            maxLines: 3,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: loading ? null : checkWeibo,
                icon: const Icon(Icons.refresh),
                label: const Text('立即检查'),
              ),
              OutlinedButton(
                onPressed: saveSettings,
                child: const Text('保存设置'),
              ),
              OutlinedButton(
                onPressed: startMonitoring,
                child: const Text('开始轮询'),
              ),
              OutlinedButton(
                onPressed: stopMonitoring,
                child: const Text('停止轮询'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '运行状态',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (loading) const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(status),
                  if (errorText.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      errorText,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '最新微博',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    latestText.isEmpty
                        ? '尚未读取微博'
                        : latestText,
                  ),
                  const SizedBox(height: 12),
                  if (latestTime.isNotEmpty)
                    Text(
                      '发布时间：$latestTime',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (latestId.isNotEmpty)
                    Text(
                      '微博 ID：$latestId',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '提示：轮询只在 App 运行期间进行。本版本尚未加入系统通知，后续再添加。',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
