import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tts.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ChangeNotifierProvider(
      create: (_) => ReaderAppState(prefs),
      child: const BookReaderApp(),
    ),
  );
}

class TextNode {
  final String text;
  final int charOffset;
  const TextNode({required this.text, required this.charOffset});
}

class BookHistoryItem {
  final String fingerprint;
  String lastKnownPath;
  String bookName;
  int lastIndex;
  int charOffset;
  String textSnippet;
  double percentage;
  String splitMode;
  int lastReadTime;

  BookHistoryItem({
    required this.fingerprint,
    required this.lastKnownPath,
    required this.bookName,
    required this.lastIndex,
    required this.charOffset,
    required this.textSnippet,
    required this.percentage,
    required this.splitMode,
    required this.lastReadTime,
  });

  Map<String, dynamic> toJson() => {
        'fingerprint': fingerprint,
        'lastKnownPath': lastKnownPath,
        'bookName': bookName,
        'lastIndex': lastIndex,
        'charOffset': charOffset,
        'textSnippet': textSnippet,
        'percentage': percentage,
        'splitMode': splitMode,
        'lastReadTime': lastReadTime,
      };

  factory BookHistoryItem.fromJson(Map<String, dynamic> json) => BookHistoryItem(
        fingerprint: json['fingerprint'] as String? ?? '',
        lastKnownPath: json['lastKnownPath'] as String? ?? '',
        bookName: json['bookName'] as String? ?? '未命名书籍',
        lastIndex: (json['lastIndex'] as num?)?.toInt() ?? 0,
        charOffset: (json['charOffset'] as num?)?.toInt() ?? 0,
        textSnippet: json['textSnippet'] as String? ?? '',
        percentage: ((json['percentage'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
        splitMode: json['splitMode'] as String? ?? 'sentence',
        lastReadTime: (json['lastReadTime'] as num?)?.toInt() ?? 0,
      );
}

class BookReaderApp extends StatelessWidget {
  const BookReaderApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: ReaderAppState.navigatorKey,
        title: '鱼听书',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          useMaterial3: true,
        ),
        home: const ReaderHomeScreen(),
      );
}

class ReaderAppState extends ChangeNotifier {
  ReaderAppState(this.prefs) {
    _loadSettings();
    _flutterTts.setLanguage('zh-CN');
    _flutterTts.setCompletionHandler(() {
      if (isPlaying && engineType == 'system') nextChunk();
    });
    _flutterTts.setErrorHandler((message) {
      if (engineType == 'system') {
        stopTTS();
        onErrorCallback?.call('系统 TTS 出错：$message');
      }
    });
    _audioPlayer.onPlayerComplete.listen((_) {
      if (isPlaying && engineType != 'system') nextChunk();
    });
  }

  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  final SharedPreferences prefs;
  final AudioPlayer _audioPlayer = AudioPlayer();
  final FlutterTts _flutterTts = FlutterTts();

  final Map<int, Uint8List> audioCache = {};
  final Set<int> _preloadingIndices = {};
  int _preloadSession = 0;

  int concurrentPreload = 6;
  int ttsTimeoutSeconds = 60;
  double speechRate = 1.0;
  int bitrate = 64; // 默认 64kbps，备用 128kbps
  bool followAlong = true; // 跟读追踪开关
  String engineType = 'microsoft';
  String splitMode = 'sentence';
  String selectedVoice = 'zh-CN-XiaoxiaoNeural';
  String fishApiKey = '';
  String libraryFolderPath = '';
  String backupFolderPath = '';

  // 多选管理状态
  bool isSelectionMode = false;
  final Set<String> selectedFingerprints = {};

  String? currentFingerprint;
  String? currentBookName;
  String? currentFilePath;
  String? currentBookContent;
  List<TextNode> textNodes = [];
  int currentIndex = 0;

  Map<String, BookHistoryItem> history = {};
  bool isPlaying = false;
  String networkStatus = '';
  Function(String)? onErrorCallback;

  Map<String, String> get voiceOptions => engineType == 'fish' ? defaultFishVoices : defaultMsVoices46;

  void _loadSettings() {
    concurrentPreload = (prefs.getInt('concurrentPreload') ?? 6).clamp(3, 15);
    ttsTimeoutSeconds = (prefs.getInt('ttsTimeoutSeconds') ?? 60).clamp(20, 120);
    speechRate = (prefs.getDouble('speechRate') ?? 1.0).clamp(0.5, 2.5);
    bitrate = prefs.getInt('bitrate') == 128 ? 128 : 64;
    followAlong = prefs.getBool('followAlong') ?? true;
    engineType = prefs.getString('engineType') ?? 'microsoft';
    splitMode = prefs.getString('splitMode') ?? 'sentence';
    selectedVoice = prefs.getString('selectedVoice') ?? 'zh-CN-XiaoxiaoNeural';
    fishApiKey = prefs.getString('fishApiKey') ?? '';
    libraryFolderPath = prefs.getString('libraryFolderPath') ?? '';

    backupFolderPath = prefs.getString('backupFolderPath') ?? '';
    if (backupFolderPath.isEmpty) {
      backupFolderPath = Platform.isAndroid
          ? '/storage/emulated/0/Download/FishReader'
          : '${Directory.current.path}/FishReaderBackup';
    }

    try {
      final raw = prefs.getString('history_librera_v4') ?? '{}';
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        history = decoded.map(
          (k, v) => MapEntry(k.toString(), BookHistoryItem.fromJson(Map<String, dynamic>.from(v as Map))),
        );
      }
    } catch (_) {
      history = {};
    }
  }

  Future<void> saveSettings() async {
    await prefs.setInt('concurrentPreload', concurrentPreload);
    await prefs.setInt('ttsTimeoutSeconds', ttsTimeoutSeconds);
    await prefs.setDouble('speechRate', speechRate);
    await prefs.setInt('bitrate', bitrate);
    await prefs.setBool('followAlong', followAlong);
    await prefs.setString('engineType', engineType);
    await prefs.setString('splitMode', splitMode);
    await prefs.setString('selectedVoice', selectedVoice);
    await prefs.setString('fishApiKey', fishApiKey);
    await prefs.setString('libraryFolderPath', libraryFolderPath);
    await prefs.setString('backupFolderPath', backupFolderPath);
    await _saveHistory();
    notifyListeners();
  }

  Future<void> _saveHistory() async {
    final encoded = jsonEncode(history.map((k, v) => MapEntry(k, v.toJson())));
    await prefs.setString('history_librera_v4', encoded);
  }

  void setFollowAlong(bool val) {
    followAlong = val;
    prefs.setBool('followAlong', val);
    notifyListeners();
  }

  // 多选控制逻辑
  void enterSelectionMode(String? initialFp) {
    isSelectionMode = true;
    selectedFingerprints.clear();
    if (initialFp != null) selectedFingerprints.add(initialFp);
    notifyListeners();
  }

  void exitSelectionMode() {
    isSelectionMode = false;
    selectedFingerprints.clear();
    notifyListeners();
  }

  void toggleSelection(String fp) {
    if (selectedFingerprints.contains(fp)) {
      selectedFingerprints.remove(fp);
      if (selectedFingerprints.isEmpty) isSelectionMode = false;
    } else {
      selectedFingerprints.add(fp);
    }
    notifyListeners();
  }

  void selectAll() {
    if (selectedFingerprints.length == history.length) {
      selectedFingerprints.clear();
    } else {
      selectedFingerprints.addAll(history.keys);
    }
    notifyListeners();
  }

  Future<void> deleteSelected() async {
    for (final fp in selectedFingerprints) {
      history.remove(fp);
      if (currentFingerprint == fp) {
        currentFingerprint = null;
        currentFilePath = null;
        currentBookName = null;
        currentBookContent = null;
        textNodes = [];
        currentIndex = 0;
      }
    }
    exitSelectionMode();
    await _saveHistory();
    notifyListeners();
  }

  static Future<String> computeFingerprint(File file) async {
    final length = await file.length();
    final raf = await file.open(mode: FileMode.read);
    try {
      final headerLen = min(4096, length);
      final header = await raf.read(headerLen);
      List<int> footer = [];
      if (length > 4096) {
        final footerLen = min(4096, length - 4096);
        await raf.setPosition(length - footerLen);
        footer = await raf.read(footerLen);
      }
      final builder = BytesBuilder(copy: false)
        ..add(utf8.encode('$length:'))
        ..add(header);
      if (footer.isNotEmpty) {
        builder.add(footer);
      }
      return md5.convert(builder.takeBytes()).toString();
    } finally {
      await raf.close();
    }
  }

  Future<void> updateHistory() async {
    final fp = currentFingerprint;
    final path = currentFilePath;
    if (fp == null || path == null || textNodes.isEmpty) return;

    final validIndex = currentIndex.clamp(0, textNodes.length - 1);
    final node = textNodes[validIndex];
    final totalLen = max(1, currentBookContent?.length ?? 1);

    final item = BookHistoryItem(
      fingerprint: fp,
      lastKnownPath: path,
      bookName: currentBookName ?? path.split(Platform.pathSeparator).last,
      lastIndex: validIndex,
      charOffset: node.charOffset,
      textSnippet: node.text.length > 30 ? node.text.substring(0, 30) : node.text,
      percentage: (node.charOffset / totalLen).clamp(0.0, 1.0),
      splitMode: splitMode,
      lastReadTime: DateTime.now().millisecondsSinceEpoch,
    );
    history[fp] = item;
    await _saveHistory();
  }

  Future<bool> checkAndRequestManagePermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    final status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return true;
    if (await Permission.storage.isGranted) return true;
    final status2 = await Permission.storage.request();
    if (status2.isGranted) return true;
    await openAppSettings();
    return false;
  }

  Future<String?> _browseSharedStorage({
    required bool chooseDirectory,
    required List<String> extensions,
    String? initialPath,
  }) async {
    if (!await checkAndRequestManagePermission()) return null;
    final navContext = navigatorKey.currentContext;
    if (navContext == null) return null;

    Directory current;
    if (initialPath != null && Directory(initialPath).existsSync()) {
      current = Directory(initialPath);
    } else {
      current = Directory('/storage/emulated/0');
      if (!await current.exists()) current = Directory('/storage');
    }

    return showDialog<String>(
      context: navContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(chooseDirectory ? '选择文件夹' : '选择文件'),
          content: SizedBox(
            width: 440,
            height: 460,
            child: FutureBuilder<List<FileSystemEntity>>(
              key: ValueKey(current.path),
              future: _listStorageSafe(current, chooseDirectory, extensions),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final entities = snapshot.data ?? [];
                return Column(
                  children: [
                    Row(
                      children: [
                        IconButton(
                          tooltip: '上一级',
                          onPressed: current.path == '/storage' || current.path == '/storage/emulated/0'
                              ? null
                              : () {
                                  current = current.parent;
                                  setDialogState(() {});
                                },
                          icon: const Icon(Icons.arrow_upward),
                        ),
                        Expanded(
                          child: Text(
                            current.path,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        if (chooseDirectory)
                          ElevatedButton(
                            onPressed: () => Navigator.pop(dialogContext, current.path),
                            child: const Text('选此目录'),
                          ),
                      ],
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: entities.isEmpty
                          ? const Center(
                              child: Text(
                                '此目录下没有匹配项\n（可点击左上角箭头返回上一级）',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey, fontSize: 13),
                              ),
                            )
                          : ListView.builder(
                              itemCount: entities.length,
                              itemBuilder: (context, index) {
                                final entity = entities[index];
                                final isDir = entity is Directory;
                                final name = entity.path.split(Platform.pathSeparator).last;
                                return ListTile(
                                  dense: true,
                                  leading: Icon(
                                    isDir ? Icons.folder : Icons.insert_drive_file,
                                    color: isDir ? Colors.amber[700] : Colors.blueGrey,
                                  ),
                                  title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
                                  onTap: () {
                                    if (isDir) {
                                      current = entity as Directory;
                                      setDialogState(() {});
                                    } else if (!chooseDirectory) {
                                      Navigator.pop(dialogContext, entity.path);
                                    }
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
          ],
        ),
      ),
    );
  }

  Future<List<FileSystemEntity>> _listStorageSafe(
    Directory dir,
    bool foldersOnly,
    List<String> extensions,
  ) async {
    final items = <FileSystemEntity>[];
    try {
      await for (final entity in dir.list(followLinks: false).handleError((_) {})) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.') && name != '.nomedia') continue;

        if (entity is Directory) {
          items.add(entity);
        } else if (!foldersOnly) {
          final ext = name.split('.').last.toLowerCase();
          if (extensions.isEmpty || extensions.contains(ext)) {
            items.add(entity);
          }
        }
      }
      items.sort((a, b) {
        final ad = a is Directory;
        final bd = b is Directory;
        if (ad != bd) return ad ? -1 : 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
    } catch (_) {}
    return items;
  }

  Future<void> importFile() async {
    String? path;
    if (Platform.isAndroid) {
      path = await _browseSharedStorage(
        chooseDirectory: false,
        extensions: ['txt', 'md', 'epub'],
        initialPath: libraryFolderPath.isNotEmpty ? libraryFolderPath : null,
      );
    } else {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['txt', 'md', 'epub'],
        withData: false,
      );
      path = result?.files.single.path;
    }
    if (path != null) await openBookByRealPath(path);
  }

  Future<bool> openBookByRealPath(String path, {bool autoPlay = false, bool resetToBeginning = false}) async {
    final file = File(path);
    if (!await file.exists()) {
      onErrorCallback?.call('文件不存在或无法访问：\n$path');
      return false;
    }
    try {
      final name = path.split(Platform.pathSeparator).last;
      final ext = name.split('.').last.toLowerCase();
      final fp = await computeFingerprint(file);

      String content;
      if (ext == 'txt' || ext == 'md') {
        content = await file.readAsString();
      } else if (ext == 'epub') {
        content = _parseEpub(await file.readAsBytes());
      } else {
        onErrorCallback?.call('不支持的文件格式');
        return false;
      }

      await stopTTS();
      currentFingerprint = fp;
      currentFilePath = path;
      currentBookName = name;
      currentBookContent = content;

      final savedItem = history[fp];
      if (savedItem != null && !resetToBeginning) {
        splitMode = savedItem.splitMode;
        savedItem.lastKnownPath = path;
        prepareTextNodes();

        if (savedItem.lastIndex >= 0 && savedItem.lastIndex < textNodes.length) {
          currentIndex = savedItem.lastIndex;
        } else {
          currentIndex = _findClosestIndexByOffset(savedItem.charOffset);
        }
      } else {
        prepareTextNodes();
        currentIndex = 0;
      }

      audioCache.clear();
      _preloadSession++;
      await updateHistory();
      notifyListeners();
      _startPreloadLoop();

      if (autoPlay) {
        unawaited(playTTS());
      }
      return true;
    } catch (e) {
      onErrorCallback?.call('打开文件失败：$e');
      return false;
    }
  }

  Future<void> closeCurrentBook() async {
    await stopTTS();
    await updateHistory();
    currentBookContent = null;
    currentBookName = null;
    currentFilePath = null;
    currentFingerprint = null;
    textNodes = [];
    currentIndex = 0;
    notifyListeners();
  }

  Future<int> scanLibraryFolder({bool forcePickNew = false}) async {
    String? targetDir = libraryFolderPath;
    if (forcePickNew || targetDir.isEmpty || !Directory(targetDir).existsSync()) {
      if (Platform.isAndroid) {
        targetDir = await _browseSharedStorage(chooseDirectory: true, extensions: const []);
      } else {
        targetDir = await FilePicker.platform.getDirectoryPath();
      }
      if (targetDir == null) return 0;
      libraryFolderPath = targetDir;
      await prefs.setString('libraryFolderPath', libraryFolderPath);
    }

    int foundCount = 0;
    try {
      final dir = Directory(libraryFolderPath);
      if (!dir.existsSync()) return 0;

      final entities = dir.listSync(recursive: true, followLinks: false);
      for (final entity in entities) {
        if (entity is! File) continue;
        final ext = entity.path.split('.').last.toLowerCase();
        if (ext != 'txt' && ext != 'md' && ext != 'epub') continue;

        foundCount++;
        final fp = await computeFingerprint(entity);
        final fileName = entity.path.split(Platform.pathSeparator).last;

        if (history.containsKey(fp)) {
          history[fp]!.lastKnownPath = entity.path;
          history[fp]!.bookName = fileName;
        } else {
          history[fp] = BookHistoryItem(
            fingerprint: fp,
            lastKnownPath: entity.path,
            bookName: fileName,
            lastIndex: 0,
            charOffset: 0,
            textSnippet: '',
            percentage: 0.0,
            splitMode: splitMode,
            lastReadTime: 0,
          );
        }
      }

      await _saveHistory();
      notifyListeners();
    } catch (e) {
      onErrorCallback?.call('扫描书库出错：$e');
    }
    return foundCount;
  }

  String _parseEpub(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final fileMap = {for (final f in archive.files) f.name: f};

      final containerFile = fileMap['META-INF/container.xml'];
      if (containerFile == null || containerFile.content is! List<int>) {
        throw const FormatException('非标准 EPUB：缺失 container.xml');
      }
      final containerXml = utf8.decode(containerFile.content as List<int>, allowMalformed: true);
      final opfPathMatch = RegExp(r'full-path="([^"]+)"', caseSensitive: false).firstMatch(containerXml);
      if (opfPathMatch == null) throw const FormatException('未找到 OPF 路径');
      final opfPath = opfPathMatch.group(1)!;

      final opfFile = fileMap[opfPath];
      if (opfFile == null || opfFile.content is! List<int>) {
        throw FormatException('缺失 OPF 文件：$opfPath');
      }
      final opfXml = utf8.decode(opfFile.content as List<int>, allowMalformed: true);
      final opfDir = opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : '';

      final manifestMap = <String, String>{};
      final itemMatches = RegExp(r'<item\b[^>]*>', caseSensitive: false).allMatches(opfXml);
      for (final m in itemMatches) {
        final tag = m.group(0)!;
        final id = RegExp(r'id="([^"]+)"').firstMatch(tag)?.group(1);
        final href = RegExp(r'href="([^"]+)"').firstMatch(tag)?.group(1);
        if (id != null && href != null) {
          manifestMap[id] = Uri.decodeFull(href);
        }
      }

      final spineIds = <String>[];
      final itemrefMatches = RegExp(r'<itemref\b[^>]*idref="([^"]+)"', caseSensitive: false).allMatches(opfXml);
      for (final m in itemrefMatches) {
        final idref = m.group(1);
        if (idref != null) spineIds.add(idref);
      }

      final output = StringBuffer();
      for (final id in spineIds) {
        final relativeHref = manifestMap[id];
        if (relativeHref == null) continue;
        final cleanPath = _resolvePath(opfDir, relativeHref);
        final contentFile = fileMap[cleanPath];
        if (contentFile == null || contentFile.content is! List<int>) continue;

        final html = utf8.decode(contentFile.content as List<int>, allowMalformed: true);
        final text = _cleanHtml(html);
        if (text.isNotEmpty) output.writeln('$text\n');
      }

      final result = output.toString().trim();
      return result.isNotEmpty ? result : 'EPUB 正文为空';
    } catch (e) {
      throw FormatException('EPUB 解析失败：$e');
    }
  }

  static String _resolvePath(String baseDir, String relativePath) {
    final combined = '$baseDir$relativePath';
    final parts = combined.split('/');
    final resolved = <String>[];
    for (final p in parts) {
      if (p == '.' || p.isEmpty) continue;
      if (p == '..') {
        if (resolved.isNotEmpty) resolved.removeLast();
      } else {
        resolved.add(p);
      }
    }
    return resolved.join('/');
  }

  static String _cleanHtml(String html) {
    var text = html
        .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(p|div|li|h[1-6]|blockquote|section)>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    return text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .join('\n\n');
  }

  void prepareTextNodes() {
    final content = currentBookContent;
    if (content == null || content.isEmpty) {
      textNodes = [];
      return;
    }

    final nodes = <TextNode>[];
    if (splitMode == 'paragraph') {
      final matches = RegExp(r'[^\r\n]+(?:\r?\n[^\r\n]+)*').allMatches(content);
      for (final m in matches) {
        final raw = m.group(0) ?? '';
        final trimmed = raw.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).join(' ');
        if (trimmed.isNotEmpty) {
          nodes.add(TextNode(text: trimmed, charOffset: m.start));
        }
      }
    } else {
      final matches = RegExp(r'[^。！？；?!;\r\n]+(?:[。！？；?!;]+|\r?\n+)?').allMatches(content);
      for (final m in matches) {
        final trimmed = m.group(0)?.trim() ?? '';
        if (trimmed.isNotEmpty) {
          nodes.add(TextNode(text: trimmed, charOffset: m.start));
        }
      }
    }

    if (nodes.isEmpty) {
      nodes.add(TextNode(text: content.trim(), charOffset: 0));
    }
    textNodes = nodes;
  }

  int _findClosestIndexByOffset(int targetOffset) {
    if (textNodes.isEmpty) return 0;
    for (var i = textNodes.length - 1; i >= 0; i--) {
      if (textNodes[i].charOffset <= targetOffset) {
        return i;
      }
    }
    return 0;
  }

  Future<void> setSplitMode(String mode) async {
    if (mode != 'sentence' && mode != 'paragraph') return;
    if (splitMode == mode) return;

    final currentOffset = textNodes.isNotEmpty && currentIndex < textNodes.length
        ? textNodes[currentIndex].charOffset
        : 0;

    splitMode = mode;
    if (currentBookContent != null) {
      prepareTextNodes();
      currentIndex = _findClosestIndexByOffset(currentOffset);
      audioCache.clear();
      _preloadSession++;
      await updateHistory();
    }
    await saveSettings();
  }

  Future<void> deleteHistory(String fp) async {
    history.remove(fp);
    if (currentFingerprint == fp) {
      await stopTTS();
      currentFingerprint = null;
      currentFilePath = null;
      currentBookName = null;
      currentBookContent = null;
      textNodes = [];
      currentIndex = 0;
    }
    await _saveHistory();
    notifyListeners();
  }

  Future<Uint8List> _synthesize(String text) {
    if (engineType == 'fish') {
      return FishAudioTTS(apiKey: fishApiKey, voices: defaultFishVoices).textToSpeech(
        text,
        selectedVoice,
        speed: speechRate,
        bitrate: bitrate,
        timeoutSeconds: ttsTimeoutSeconds,
      );
    }
    return MicrosoftTranslatorTTS.synthesize(
      text,
      selectedVoice,
      speed: speechRate,
      bitrate: bitrate,
      timeoutSeconds: ttsTimeoutSeconds,
    );
  }

  Future<void> previewVoice() async {
    try {
      if (engineType == 'system') {
        await _flutterTts.setSpeechRate(speechRate * 0.5);
        await _flutterTts.speak('您好，这是正在测试的声音效果。');
      } else {
        final bytes = await _synthesize('您好，这是正在测试的声音效果。');
        await _playBytes(bytes);
      }
    } catch (e) {
      onErrorCallback?.call('试听失败：$e');
    }
  }

  Future<void> _playBytes(Uint8List bytes) async {
    await _audioPlayer.play(BytesSource(bytes));
  }

  Future<void> playTTS() async {
    if (textNodes.isEmpty || currentIndex >= textNodes.length) return;
    isPlaying = true;
    await updateHistory();
    notifyListeners();
    try {
      final text = textNodes[currentIndex].text;
      if (engineType == 'system') {
        await _flutterTts.setSpeechRate(speechRate * 0.5);
        await _flutterTts.speak(text);
      } else {
        final bytes = audioCache.remove(currentIndex) ?? await _synthesize(text);
        if (!isPlaying) return;
        await _playBytes(bytes);
        _startPreloadLoop();
      }
    } catch (e) {
      await stopTTS();
      onErrorCallback?.call('语音合成失败：$e');
    }
  }

  Future<void> stopTTS() async {
    isPlaying = false;
    await _audioPlayer.stop();
    await _flutterTts.stop();
    await updateHistory();
    notifyListeners();
  }

  void nextChunk() {
    if (currentIndex < textNodes.length - 1) {
      currentIndex++;
      _pruneCache();
      unawaited(updateHistory());
      notifyListeners();
      if (isPlaying) unawaited(playTTS());
    } else {
      unawaited(stopTTS());
    }
  }

  void prevChunk() {
    if (currentIndex <= 0) return;
    currentIndex--;
    _pruneCache();
    unawaited(updateHistory());
    notifyListeners();
    if (isPlaying) unawaited(playTTS());
  }

  void jumpTo(int index) {
    if (index < 0 || index >= textNodes.length) return;
    _preloadSession++;
    currentIndex = index;
    _pruneCache();
    unawaited(updateHistory());
    notifyListeners();
    if (isPlaying) unawaited(playTTS());
  }

  void _pruneCache() {
    audioCache.removeWhere(
      (idx, _) => idx < currentIndex - 1 || idx > currentIndex + concurrentPreload + 2,
    );
  }

  void _startPreloadLoop() {
    if (engineType == 'system') return;
    final session = _preloadSession;
    for (var offset = 1; offset <= concurrentPreload; offset++) {
      final target = currentIndex + offset;
      if (target < textNodes.length && !audioCache.containsKey(target) && !_preloadingIndices.contains(target)) {
        unawaited(_preloadChunk(target, session));
      }
    }
  }

  Future<void> _preloadChunk(int index, int session) async {
    _preloadingIndices.add(index);
    try {
      final bytes = await _synthesize(textNodes[index].text);
      if (_preloadSession != session) return;
      audioCache[index] = bytes;
      _pruneCache();
      notifyListeners();
    } catch (_) {
    } finally {
      _preloadingIndices.remove(index);
    }
  }

  Map<String, dynamic> _backupData() => {
        'version': 5,
        'exportTime': DateTime.now().toIso8601String(),
        'concurrentPreload': concurrentPreload,
        'ttsTimeoutSeconds': ttsTimeoutSeconds,
        'speechRate': speechRate,
        'bitrate': bitrate,
        'followAlong': followAlong,
        'engineType': engineType,
        'splitMode': splitMode,
        'selectedVoice': selectedVoice,
        'fishApiKey': fishApiKey,
        'libraryFolderPath': libraryFolderPath,
        'backupFolderPath': backupFolderPath,
        'history': history.map((k, v) => MapEntry(k, v.toJson())),
      };

  Future<void> changeBackupFolder() async {
    String? newDir;
    if (Platform.isAndroid) {
      newDir = await _browseSharedStorage(
        chooseDirectory: true,
        extensions: const [],
        initialPath: backupFolderPath,
      );
    } else {
      newDir = await FilePicker.platform.getDirectoryPath();
    }
    if (newDir != null && newDir.isNotEmpty) {
      backupFolderPath = newDir;
      await saveSettings();
    }
  }

  /// 导出单一备份文件（已移除冗余的 latest 文件）
  Future<String?> exportBackupReliable() async {
    try {
      if (!await checkAndRequestManagePermission()) {
        throw Exception('未授予存储管理权限');
      }

      final targetFolder = Directory(backupFolderPath);
      if (!await targetFolder.exists()) {
        await targetFolder.create(recursive: true);
      }

      final dateStr = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final fileName = 'fish_reader_backup_$dateStr.json';
      final file = File('${targetFolder.path}/$fileName');

      final content = jsonEncode(_backupData());
      await file.writeAsString(content, flush: true);

      return file.path;
    } catch (e) {
      onErrorCallback?.call('导出备份失败：$e');
      return null;
    }
  }

  Future<List<File>> getAvailableBackups() async {
    try {
      final dir = Directory(backupFolderPath);
      if (!await dir.exists()) return [];
      final files = <File>[];
      await for (final entity in dir.list(followLinks: false).handleError((_) {})) {
        if (entity is File && entity.path.toLowerCase().endsWith('.json')) {
          files.add(entity);
        }
      }
      files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      return files;
    } catch (_) {
      return [];
    }
  }

  Future<bool> importBackupFromFilePath(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final data = jsonDecode(await file.readAsString());
      return _restoreBackup(data);
    } catch (e) {
      onErrorCallback?.call('恢复备份失败：$e');
      return false;
    }
  }

  Future<bool> _restoreBackup(dynamic data) async {
    if (data is! Map) throw const FormatException('备份格式无效');
    concurrentPreload = ((data['concurrentPreload'] as num?)?.toInt() ?? 6).clamp(3, 15);
    ttsTimeoutSeconds = ((data['ttsTimeoutSeconds'] as num?)?.toInt() ?? 60).clamp(20, 120);
    speechRate = ((data['speechRate'] as num?)?.toDouble() ?? 1).clamp(0.5, 2.5);
    bitrate = (data['bitrate'] as num?)?.toInt() == 128 ? 128 : 64;
    followAlong = data['followAlong'] as bool? ?? true;
    engineType = data['engineType'] == 'fish' ? 'fish' : (data['engineType'] == 'system' ? 'system' : 'microsoft');
    splitMode = data['splitMode'] == 'paragraph' ? 'paragraph' : 'sentence';
    fishApiKey = data['fishApiKey'] is String ? data['fishApiKey'] as String : '';
    libraryFolderPath = data['libraryFolderPath'] is String ? data['libraryFolderPath'] as String : '';
    backupFolderPath = data['backupFolderPath'] is String ? data['backupFolderPath'] as String : backupFolderPath;

    final rawVoice = data['selectedVoice'];
    final voices = engineType == 'fish' ? defaultFishVoices : defaultMsVoices46;
    selectedVoice = rawVoice is String && voices.containsKey(rawVoice) ? rawVoice : voices.keys.first;

    history = {};
    if (data['history'] is Map) {
      final map = data['history'] as Map;
      for (final entry in map.entries) {
        if (entry.value is Map) {
          history[entry.key.toString()] = BookHistoryItem.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
        }
      }
    }

    currentFingerprint = null;
    currentBookName = null;
    currentFilePath = null;
    currentBookContent = null;
    textNodes = [];
    currentIndex = 0;
    exitSelectionMode();
    await saveSettings();

    if (libraryFolderPath.isNotEmpty && Directory(libraryFolderPath).existsSync()) {
      unawaited(scanLibraryFolder());
    }

    notifyListeners();
    return true;
  }

  Future<void> testNetwork() async {
    networkStatus = '正在测试…';
    notifyListeners();
    final result = engineType == 'fish'
        ? await FishAudioTTS(apiKey: fishApiKey, voices: defaultFishVoices).testConnectivity()
        : await MicrosoftTranslatorTTS.testConnectivity();
    final ms = result['latency'] ?? 0;
    final quality = ms < 300 ? '较快' : (ms < 1000 ? '一般' : '较慢');
    networkStatus = '${result['success'] == true ? '连接成功' : '连接失败'} · ${ms}ms（$quality）\n${result['msg'] ?? ''}';
    notifyListeners();
  }
}

class ReaderHomeScreen extends StatefulWidget {
  const ReaderHomeScreen({super.key});
  @override
  State<ReaderHomeScreen> createState() => _ReaderHomeScreenState();
}

class _ReaderHomeScreenState extends State<ReaderHomeScreen> with WidgetsBindingObserver {
  final ScrollController _scrollController = ScrollController();
  String? _lastLoadedBookPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = context.read<ReaderAppState>();
      state.onErrorCallback = (message) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
          );
        }
      };
      if (state.libraryFolderPath.isNotEmpty) {
        state.scanLibraryFolder();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      unawaited(context.read<ReaderAppState>().updateHistory());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ReaderAppState>();

    // 初次打开书籍且跟读开启时，平滑定位到断点
    if (state.currentBookContent != null) {
      if (_lastLoadedBookPath != state.currentFilePath) {
        _lastLoadedBookPath = state.currentFilePath;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (state.followAlong) {
            _scrollToCurrent(state, state.currentIndex);
          }
        });
      }
    } else {
      _lastLoadedBookPath = null;
    }

    return Scaffold(
      appBar: AppBar(
        leading: state.currentBookContent != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回书架',
                onPressed: state.closeCurrentBook,
              )
            : (state.isSelectionMode
                ? IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: '取消多选',
                    onPressed: state.exitSelectionMode,
                  )
                : null),
        title: Text(
          state.currentBookContent != null
              ? (state.currentBookName ?? '正文阅读')
              : (state.isSelectionMode
                  ? '已选择 ${state.selectedFingerprints.length} 项'
                  : '鱼听书'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
        actions: state.currentBookContent != null
            ? [
                // 跟读开关快捷键
                IconButton(
                  tooltip: state.followAlong ? '跟读追踪：已开启' : '跟读追踪：已关闭',
                  icon: Icon(state.followAlong ? Icons.gps_fixed : Icons.gps_off),
                  onPressed: () => state.setFollowAlong(!state.followAlong),
                ),
                IconButton(
                  tooltip: '设置与备份',
                  icon: const Icon(Icons.settings),
                  onPressed: () => _showSettingsDialog(context, state),
                ),
              ]
            : (state.isSelectionMode
                ? [
                    IconButton(
                      tooltip: '全选/反选',
                      icon: const Icon(Icons.select_all),
                      onPressed: state.selectAll,
                    ),
                    IconButton(
                      tooltip: '批量删除',
                      icon: const Icon(Icons.delete_forever),
                      onPressed: state.selectedFingerprints.isEmpty
                          ? null
                          : () => _confirmBatchDelete(context, state),
                    ),
                  ]
                : [
                    IconButton(
                      tooltip: '刷新书库',
                      icon: const Icon(Icons.sync),
                      onPressed: () async {
                        final c = await state.scanLibraryFolder();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('已刷新书库，共检索到 $c 本图书')),
                          );
                        }
                      },
                    ),
                    IconButton(
                      tooltip: '单本导入',
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: state.importFile,
                    ),
                    IconButton(
                      tooltip: '设置与备份',
                      icon: const Icon(Icons.settings),
                      onPressed: () => _showSettingsDialog(context, state),
                    ),
                  ]),
      ),
      body: Column(
        children: [
          Expanded(child: state.currentBookContent == null ? _libraryHomeView(state) : _readerView(state)),
          if (state.currentBookContent != null) _buildControlPanel(context, state),
        ],
      ),
    );
  }

  /// 书库首页：无图书时展示目录配置卡片，有图书后全屏展示书单
  Widget _libraryHomeView(ReaderAppState state) {
    // 没图书时才显示大目录卡片
    if (state.history.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_special, size: 72, color: Colors.deepPurple),
              const SizedBox(height: 16),
              const Text('书库暂无书籍', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 8),
              Text(
                state.libraryFolderPath.isEmpty
                    ? '请选择保存电子书的固定目录，软件将自动递归检索所有合规书籍。'
                    : '当前书库：${state.libraryFolderPath}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: () async {
                      final count = await state.scanLibraryFolder(forcePickNew: true);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已选定书库，发现 $count 本图书')),
                        );
                      }
                    },
                    icon: const Icon(Icons.create_new_folder),
                    label: const Text('设定书库目录'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: state.importFile,
                    icon: const Icon(Icons.file_open),
                    label: const Text('单本文件打开'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final recentBooks = state.history.values.where((b) => b.lastReadTime > 0).toList()
      ..sort((a, b) => b.lastReadTime.compareTo(a.lastReadTime));

    final allBooks = state.history.values.toList()
      ..sort((a, b) => a.bookName.toLowerCase().compareTo(b.bookName.toLowerCase()));

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      children: [
        if (recentBooks.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(Icons.history, size: 18, color: Colors.deepPurple),
                SizedBox(width: 6),
                Text('继续阅读 (Recent)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ],
            ),
          ),
          ...recentBooks.take(4).map((item) => _buildBookCard(state, item)),
          const Divider(height: 18),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              const Icon(Icons.library_books, size: 18, color: Colors.deepPurple),
              const SizedBox(width: 6),
              Text('全部书籍 (${allBooks.length})', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const Spacer(),
              if (!state.isSelectionMode)
                TextButton.icon(
                  onPressed: () => state.enterSelectionMode(null),
                  icon: const Icon(Icons.checklist, size: 16),
                  label: const Text('批量管理', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ),
        ...allBooks.map((item) => _buildBookCard(state, item)),
      ],
    );
  }

  /// 纯净版书籍卡片：无路径、无冗余图标，100% 空间给书名与进度
  Widget _buildBookCard(ReaderAppState state, BookHistoryItem item) {
    final isSelected = state.selectedFingerprints.contains(item.fingerprint);

    return Card(
      elevation: isSelected ? 3 : 1,
      color: isSelected ? Colors.deepPurple.withOpacity(0.12) : null,
      margin: const EdgeInsets.symmetric(vertical: 3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: isSelected ? const BorderSide(color: Colors.deepPurple, width: 1.5) : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          if (state.isSelectionMode) {
            state.toggleSelection(item.fingerprint);
          } else {
            state.openBookByRealPath(item.lastKnownPath);
          }
        },
        onLongPress: () {
          if (!state.isSelectionMode) {
            _showBookContextMenu(context, state, item);
          } else {
            state.toggleSelection(item.fingerprint);
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              if (state.isSelectionMode) ...[
                Checkbox(
                  value: isSelected,
                  onChanged: (_) => state.toggleSelection(item.fingerprint),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.bookName,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '进度：${(item.percentage * 100).toStringAsFixed(1)}% '
                      '(${item.lastIndex + 1} 项)'
                      '${item.textSnippet.isNotEmpty ? " · “${item.textSnippet}”" : ""}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 长按右键菜单
  void _showBookContextMenu(BuildContext context, ReaderAppState state, BookHistoryItem item) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                item.bookName,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.play_arrow, color: Colors.deepPurple),
              title: const Text('继续朗读'),
              onTap: () {
                Navigator.pop(ctx);
                state.openBookByRealPath(item.lastKnownPath, autoPlay: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: const Text('从头开始朗读'),
              onTap: () {
                Navigator.pop(ctx);
                state.openBookByRealPath(item.lastKnownPath, autoPlay: true, resetToBeginning: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.checklist),
              title: const Text('多选管理'),
              onTap: () {
                Navigator.pop(ctx);
                state.enterSelectionMode(item.fingerprint);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除记录', style: TextStyle(color: Colors.red)),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (dCtx) => AlertDialog(
                    title: const Text('确认删除？'),
                    content: const Text('仅删除书架与阅读记录，不会删除手机上的原书文件。'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('取消')),
                      TextButton(onPressed: () => Navigator.pop(dCtx, true), child: const Text('删除')),
                    ],
                  ),
                );
                if (ok == true) await state.deleteHistory(item.fingerprint);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmBatchDelete(BuildContext context, ReaderAppState state) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('批量删除 ${state.selectedFingerprints.length} 项记录？'),
        content: const Text('仅从书架中移除所选图书的阅读进度，不会删除原始文件。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(ctx);
              state.deleteSelected();
            },
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
  }

  Widget _readerView(ReaderAppState state) => ListView.builder(
        controller: _scrollController,
        itemCount: state.textNodes.length,
        itemBuilder: (context, index) {
          final selected = index == state.currentIndex;
          return InkWell(
            onTap: () {
              state.jumpTo(index);
              if (state.followAlong) {
                WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent(state, index));
              }
            },
            child: Container(
              width: double.infinity,
              margin: EdgeInsets.fromLTRB(14, state.splitMode == 'paragraph' ? 8 : 3, 14, state.splitMode == 'paragraph' ? 8 : 3),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: selected ? Colors.deepPurple.withOpacity(0.14) : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: selected ? Border.all(color: Colors.deepPurple.withOpacity(0.5)) : null,
              ),
              child: Text(
                state.textNodes[index].text,
                textAlign: TextAlign.start,
                style: TextStyle(
                  fontSize: 17,
                  height: 1.6,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  color: selected ? Colors.deepPurple : Colors.black87,
                ),
              ),
            ),
          );
        },
      );

  /// 控制栏：集成全文滑条、断点信息、播放按钮
  Widget _buildControlPanel(BuildContext context, ReaderAppState state) {
    final total = state.textNodes.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 全文滑条快速定位
            if (total > 0)
              Row(
                children: [
                  Text(
                    '${state.currentIndex + 1}/$total',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  Expanded(
                    child: Slider(
                      value: state.currentIndex.toDouble().clamp(0.0, max(0, total - 1).toDouble()),
                      min: 0,
                      max: max(1, total - 1).toDouble(),
                      divisions: max(1, total - 1),
                      label: '${((state.currentIndex + 1) / total * 100).toStringAsFixed(1)}%',
                      onChanged: (val) {
                        final idx = val.round();
                        state.jumpTo(idx);
                        if (state.followAlong) {
                          _scrollToCurrent(state, idx);
                        }
                      },
                    ),
                  ),
                  Text(
                    '${((state.currentIndex + 1) / total * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: '上一句/段',
                  icon: const Icon(Icons.skip_previous, size: 30),
                  onPressed: () {
                    state.prevChunk();
                    if (state.followAlong) _scrollToCurrent(state, state.currentIndex);
                  },
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(shape: const CircleBorder(), padding: const EdgeInsets.all(12)),
                  onPressed: total == 0 ? null : (state.isPlaying ? state.stopTTS : state.playTTS),
                  child: Icon(state.isPlaying ? Icons.pause : Icons.play_arrow, size: 32),
                ),
                IconButton(
                  tooltip: '下一句/段',
                  icon: const Icon(Icons.skip_next, size: 30),
                  onPressed: () {
                    state.nextChunk();
                    if (state.followAlong) _scrollToCurrent(state, state.currentIndex);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _scrollToCurrent(ReaderAppState state, int index) {
    if (!state.followAlong) return;
    if (!_scrollController.hasClients || state.textNodes.isEmpty) return;
    double offset = 0;
    for (var i = 0; i < index && i < state.textNodes.length; i++) {
      final len = state.textNodes[i].text.length;
      final lines = (len / 22).ceil().clamp(1, 40);
      offset += (state.splitMode == 'paragraph' ? 24.0 : 14.0) + (lines * 27.0);
    }
    final target = offset.clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(target, duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
  }

  void _showSettingsDialog(BuildContext context, ReaderAppState state) {
    final apiKeyController = TextEditingController(text: state.fishApiKey);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('朗读设置与备份'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    value: state.engineType,
                    decoration: const InputDecoration(labelText: 'TTS 引擎'),
                    items: const [
                      DropdownMenuItem(value: 'microsoft', child: Text('Microsoft TTS')),
                      DropdownMenuItem(value: 'fish', child: Text('Fish Audio')),
                      DropdownMenuItem(value: 'system', child: Text('系统离线 TTS')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        state.engineType = value;
                        state.selectedVoice = state.voiceOptions.keys.first;
                        state.audioCache.clear();
                        setDialogState(() {});
                      }
                    },
                  ),
                  if (state.engineType == 'fish')
                    TextField(
                      controller: apiKeyController,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Fish Audio API Key'),
                    ),
                  if (state.engineType != 'system')
                    DropdownButtonFormField<String>(
                      value: state.voiceOptions.containsKey(state.selectedVoice)
                          ? state.selectedVoice
                          : state.voiceOptions.keys.first,
                      decoration: const InputDecoration(labelText: '发音人'),
                      items: state.voiceOptions.entries
                          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)))
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          state.selectedVoice = value;
                          state.audioCache.clear();
                          setDialogState(() {});
                        }
                      },
                    ),
                  DropdownButtonFormField<String>(
                    value: state.splitMode,
                    decoration: const InputDecoration(labelText: '朗读断句方式'),
                    items: const [
                      DropdownMenuItem(value: 'sentence', child: Text('按句子朗读')),
                      DropdownMenuItem(value: 'paragraph', child: Text('按段落朗读')),
                    ],
                    onChanged: (value) async {
                      if (value != null) {
                        await state.setSplitMode(value);
                        setDialogState(() {});
                      }
                    },
                  ),
                  Row(
                    children: [
                      const Text('语速'),
                      Expanded(
                        child: Slider(
                          value: state.speechRate,
                          min: 0.5,
                          max: 2.5,
                          divisions: 20,
                          label: '${state.speechRate.toStringAsFixed(1)}x',
                          onChanged: (v) => setDialogState(() {
                            state.speechRate = v;
                            state.audioCache.clear();
                          }),
                        ),
                      ),
                      Text('${state.speechRate.toStringAsFixed(1)}x'),
                    ],
                  ),
                  // 全局音频质量选择（默认 64k，备用 128k）
                  if (state.engineType != 'system')
                    DropdownButtonFormField<int>(
                      value: state.bitrate,
                      decoration: const InputDecoration(labelText: '音频质量'),
                      items: const [
                        DropdownMenuItem(value: 64, child: Text('64 kbps (默认 · 极速流畅)')),
                        DropdownMenuItem(value: 128, child: Text('128 kbps (高品质 · 清晰)')),
                      ],
                      onChanged: (value) {
                        if (value != null) setDialogState(() => state.bitrate = value);
                      },
                    ),
                  // 跟读追踪开关
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('跟读追踪滚屏'),
                    subtitle: const Text('播放时屏幕自动跟随当前句子滚动'),
                    value: state.followAlong,
                    onChanged: (val) {
                      setDialogState(() => state.setFollowAlong(val));
                    },
                  ),
                  Row(
                    children: [
                      const Text('预读'),
                      Expanded(
                        child: Slider(
                          value: state.concurrentPreload.toDouble(),
                          min: 3,
                          max: 15,
                          divisions: 12,
                          label: '${state.concurrentPreload} 项',
                          onChanged: (v) => setDialogState(() => state.concurrentPreload = v.toInt()),
                        ),
                      ),
                      Text('${state.concurrentPreload}'),
                    ],
                  ),
                  Row(
                    children: [
                      const Text('超时'),
                      Expanded(
                        child: Slider(
                          value: state.ttsTimeoutSeconds.toDouble(),
                          min: 20,
                          max: 120,
                          divisions: 20,
                          label: '${state.ttsTimeoutSeconds} 秒',
                          onChanged: (v) => setDialogState(() => state.ttsTimeoutSeconds = v.toInt()),
                        ),
                      ),
                      Text('${state.ttsTimeoutSeconds}s'),
                    ],
                  ),
                  TextButton.icon(
                    onPressed: state.previewVoice,
                    icon: const Icon(Icons.volume_up),
                    label: const Text('试听发音'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      state.fishApiKey = apiKeyController.text.trim();
                      await state.testNetwork();
                      setDialogState(() {});
                    },
                    icon: const Icon(Icons.network_check),
                    label: const Text('测试网络'),
                  ),
                  if (state.networkStatus.isNotEmpty)
                    Text(state.networkStatus, style: const TextStyle(fontSize: 12)),
                  const Divider(),

                  // 书库目录设置项
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('书库目录', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    subtitle: Text(
                      state.libraryFolderPath.isEmpty ? '未设定' : state.libraryFolderPath,
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: OutlinedButton(
                      onPressed: () async {
                        await state.scanLibraryFolder(forcePickNew: true);
                        setDialogState(() {});
                      },
                      child: const Text('更改目录'),
                    ),
                  ),

                  // 备份目录设置项
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('备份保存目录', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    subtitle: Text(
                      state.backupFolderPath,
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: OutlinedButton(
                      onPressed: () async {
                        await state.changeBackupFolder();
                        setDialogState(() {});
                      },
                      child: const Text('更改目录'),
                    ),
                  ),
                  const SizedBox(height: 8),

                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () async {
                          state.fishApiKey = apiKeyController.text.trim();
                          final path = await state.exportBackupReliable();
                          if (path != null && mounted) {
                            showDialog<void>(
                              context: dialogContext,
                              builder: (ctx) => AlertDialog(
                                title: const Text('备份导出成功'),
                                content: Text('备份文件已写入目录：\n\n$path'),
                                actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('好'))],
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.save_alt),
                        label: const Text('一键导出备份'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _showRestorePicker(dialogContext, state, setDialogState),
                        icon: const Icon(Icons.restore),
                        label: const Text('选择备份恢复'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                state.fishApiKey = apiKeyController.text.trim();
                await state.saveSettings();
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    ).whenComplete(apiKeyController.dispose);
  }

  void _showRestorePicker(
    BuildContext parentDialogContext,
    ReaderAppState state,
    void Function(void Function()) setParentState,
  ) {
    showDialog<void>(
      context: parentDialogContext,
      builder: (pickerCtx) => FutureBuilder<List<File>>(
        future: state.getAvailableBackups(),
        builder: (context, snapshot) {
          final files = snapshot.data ?? [];
          return AlertDialog(
            title: const Text('选择备份恢复'),
            content: SizedBox(
              width: 440,
              height: 380,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前备份目录: ${state.backupFolderPath}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  Expanded(
                    child: snapshot.connectionState != ConnectionState.done
                        ? const Center(child: CircularProgressIndicator())
                        : files.isEmpty
                            ? const Center(
                                child: Text('当前备份目录中没有发现 .json 备份\n请点击下方按钮从其他路径选取', textAlign: TextAlign.center),
                              )
                            : ListView.builder(
                                itemCount: files.length,
                                itemBuilder: (ctx, index) {
                                  final f = files[index];
                                  final name = f.path.split(Platform.pathSeparator).last;
                                  final sizeKb = (f.lengthSync() / 1024).toStringAsFixed(1);
                                  return ListTile(
                                    dense: true,
                                    leading: const Icon(Icons.settings_backup_restore, color: Colors.deepPurple),
                                    title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                    subtitle: Text('大小：$sizeKb KB'),
                                    onTap: () async {
                                      Navigator.pop(pickerCtx);
                                      final ok = await state.importBackupFromFilePath(f.path);
                                      if (ok && mounted) {
                                        setParentState(() {});
                                        ScaffoldMessenger.of(this.context).showSnackBar(
                                          SnackBar(content: Text('已从 $name 恢复成功！')),
                                        );
                                      }
                                    },
                                  );
                                },
                              ),
                  ),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton.icon(
                        onPressed: () async {
                          Navigator.pop(pickerCtx);
                          final path = await state._browseSharedStorage(
                            chooseDirectory: false,
                            extensions: ['json'],
                            initialPath: state.backupFolderPath,
                          );
                          if (path != null) {
                            final ok = await state.importBackupFromFilePath(path);
                            if (ok && mounted) {
                              setParentState(() {});
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                const SnackBar(content: Text('备份恢复成功！')),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.folder_open),
                        label: const Text('浏览存储选择'),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          Navigator.pop(pickerCtx);
                          final res = await FilePicker.platform.pickFiles(type: FileType.any);
                          final p = res?.files.single.path;
                          if (p != null) {
                            final ok = await state.importBackupFromFilePath(p);
                            if (ok && mounted) {
                              setParentState(() {});
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                const SnackBar(content: Text('备份恢复成功！')),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.phonelink_setup),
                        label: const Text('系统选择器'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(pickerCtx), child: const Text('取消')),
            ],
          );
        },
      ),
    );
  }
}
