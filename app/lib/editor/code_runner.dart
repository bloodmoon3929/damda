import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Runs a code block on this computer (desktop only), like Obsidian's
/// "Execute Code" plugin: the code goes to a temp folder, is compiled if
/// needed (C/C++ with g++/gcc/clang), then run with a time limit. Nothing is
/// sent anywhere; it only runs when the user presses ▶.
class CodeRunResult {
  CodeRunResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.elapsed,
    this.timedOut = false,
    this.compileFailed = false,
  });

  final String stdout;
  final String stderr;
  final int? exitCode;
  final Duration elapsed;
  final bool timedOut;
  final bool compileFailed;
}

class CodeRunnerException implements Exception {
  CodeRunnerException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// How one language is run. `{src}` / `{out}` in args are replaced.
class _Lang {
  const _Lang(this.ext, this.candidates, {this.compile, this.run});

  final String ext;

  /// Programs to look for, first found wins.
  final List<String> candidates;

  /// Compile step (C/C++), then [run] executes `{out}`.
  final List<String>? compile;
  final List<String>? run;
}

const _cppFlags = ['-std=c++20', '-O2', '{src}', '-o', '{out}'];
const _cFlags = ['-std=c17', '-O2', '{src}', '-o', '{out}'];

const _langs = <String, _Lang>{
  'cpp': _Lang('.cpp', ['g++', 'clang++'], compile: _cppFlags),
  'c': _Lang('.c', ['gcc', 'clang'], compile: _cFlags),
  'python': _Lang(
    '.py',
    ['python', 'python3', 'py'],
    run: ['-I', '-X', 'utf8', '{src}'],
  ),
  'javascript': _Lang('.js', ['node'], run: ['{src}']),
  'dart': _Lang('.dart', ['dart'], run: ['run', '{src}']),
  'bash': _Lang('.sh', ['bash'], run: ['{src}']),
  'powershell': _Lang(
    '.ps1',
    ['pwsh', 'powershell'],
    run: ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '{src}'],
  ),
};

const _aliases = {
  'c++': 'cpp',
  'cc': 'cpp',
  'cxx': 'cpp',
  'py': 'python',
  'python3': 'python',
  'js': 'javascript',
  'node': 'javascript',
  'sh': 'bash',
  'shell': 'bash',
  'ps1': 'powershell',
  'pwsh': 'powershell',
};

String? runnableLanguage(String language) {
  final l = language.trim().toLowerCase();
  final key = _aliases[l] ?? l;
  return _langs.containsKey(key) ? key : null;
}

bool get codeRunSupported =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

final _found = <String, String?>{};

/// Full path of [program], from PATH or common install places.
Future<String?> findProgram(String program) async {
  if (_found.containsKey(program)) return _found[program];
  String? hit;
  try {
    final r = await Process.run(Platform.isWindows ? 'where' : 'which', [
      program,
    ], runInShell: Platform.isWindows);
    if (r.exitCode == 0) {
      hit = '${r.stdout}'.split(RegExp(r'\r?\n')).first.trim();
    }
  } catch (_) {}
  if ((hit == null || hit.isEmpty) && Platform.isWindows) {
    final pf = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final local = Platform.environment['LOCALAPPDATA'] ?? '';
    // winget installs (e.g. WinLibs g++) land here; a PATH change only
    // reaches apps started afterwards.
    final winget = Directory(p.join(local, 'Microsoft', 'WinGet', 'Packages'));
    final wingetBins = [
      if (winget.existsSync())
        for (final d in winget.listSync().whereType<Directory>())
          if (p.basename(d.path).contains('WinLibs') ||
              p.basename(d.path).contains('MinGW'))
            p.join(d.path, 'mingw64', 'bin'),
    ];
    for (final dir in [
      ...wingetBins,
      '$pf\\Git\\bin', // bash from Git for Windows
      'C:\\msys64\\ucrt64\\bin',
      'C:\\msys64\\mingw64\\bin',
      'C:\\mingw64\\bin',
      '$local\\Microsoft\\WinGet\\Links',
    ]) {
      final f = File(p.join(dir, '$program.exe'));
      if (f.existsSync()) {
        hit = f.path;
        break;
      }
    }
  }
  // An app opened from Finder/Dock gets PATH=/usr/bin:/bin:/usr/sbin:/sbin,
  // so Homebrew installs (node, newer python…) aren't found by `which`.
  if ((hit == null || hit.isEmpty) && Platform.isMacOS) {
    final home = Platform.environment['HOME'] ?? '';
    for (final dir in [
      '/opt/homebrew/bin', // Apple silicon Homebrew
      '/usr/local/bin', // Intel Homebrew, python.org, node installers
      if (home.isNotEmpty) '$home/.local/bin',
    ]) {
      final f = File(p.join(dir, program));
      if (f.existsSync()) {
        hit = f.path;
        break;
      }
    }
  }
  return _found[program] = (hit == null || hit.isEmpty) ? null : hit;
}

/// What is needed to run [language] when nothing was found.
String missingHint(String language) => switch (runnableLanguage(language)) {
  'cpp' || 'c' when Platform.isMacOS =>
    'C/C++ 컴파일러가 없어요. 터미널에서 xcode-select --install 을 실행하세요.',
  'cpp' || 'c' when Platform.isLinux =>
    'C/C++ 컴파일러가 없어요. g++ (예: sudo apt install g++)를 설치하세요.',
  'cpp' || 'c' => 'C/C++ 컴파일러(g++)가 없어요. MinGW-w64(WinLibs 또는 MSYS2)를 설치하세요.',
  'bash' => 'bash가 없어요. Git for Windows를 설치하면 함께 들어와요.',
  'javascript' when Platform.isMacOS =>
    'node가 없어요. nodejs.org에서 받거나 brew install node 로 설치하세요.',
  final l => '$l 실행 프로그램을 찾지 못했어요.',
};

/// The running process, so a run can be stopped.
class CodeRun {
  CodeRun._(this.result, this._kill);
  final Future<CodeRunResult> result;
  final void Function() _kill;
  void stop() => _kill();
}

CodeRun runCode(
  String language,
  String source, {
  Duration timeout = const Duration(seconds: 15),
}) {
  Process? process;
  var stopped = false;
  Future<CodeRunResult> go() async {
    final key = runnableLanguage(language);
    if (key == null) throw CodeRunnerException('실행할 수 없는 언어예요: $language');
    final lang = _langs[key]!;
    String? exe;
    for (final c in lang.candidates) {
      exe = await findProgram(c);
      if (exe != null) break;
    }
    if (exe == null) throw CodeRunnerException(missingHint(key));

    final dir = await Directory.systemTemp.createTemp('notes_run');
    final src = p.join(dir.path, 'main${lang.ext}');
    final out = p.join(dir.path, Platform.isWindows ? 'main.exe' : 'main');
    // C/C++ sources are read as UTF-8, so Korean in strings prints right.
    await File(src).writeAsString(source);
    List<String> fill(List<String> args) => [
      for (final a in args) a.replaceAll('{src}', src).replaceAll('{out}', out),
    ];
    final watch = Stopwatch()..start();
    try {
      var program = exe;
      var args = fill(lang.run ?? const []);
      if (lang.compile != null) {
        final c = await Process.run(
          exe,
          [
            ...fill(lang.compile!),
            // No MinGW DLLs needed at run time; sources are UTF-8.
            if (Platform.isWindows) ...['-static', '-finput-charset=UTF-8'],
          ],
          workingDirectory: dir.path,
          stdoutEncoding: const Utf8Codec(allowMalformed: true),
          stderrEncoding: const Utf8Codec(allowMalformed: true),
        );
        if (c.exitCode != 0) {
          return CodeRunResult(
            stdout: '${c.stdout}',
            stderr: '${c.stderr}',
            exitCode: c.exitCode,
            elapsed: watch.elapsed,
            compileFailed: true,
          );
        }
        program = out;
        args = const [];
      }
      final proc = await Process.start(
        program,
        args,
        workingDirectory: dir.path,
        environment: const {'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'},
      );
      process = proc;
      if (stopped) proc.kill();
      await proc.stdin.close();
      const decoder = Utf8Decoder(allowMalformed: true);
      final so = proc.stdout.transform(decoder).join();
      final se = proc.stderr.transform(decoder).join();
      var timedOut = false;
      final code = await proc.exitCode.timeout(
        timeout,
        onTimeout: () {
          timedOut = true;
          proc.kill();
          return -1;
        },
      );
      return CodeRunResult(
        stdout: await so,
        stderr: await se,
        exitCode: stopped ? null : code,
        elapsed: watch.elapsed,
        timedOut: timedOut,
      );
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // The process may still hold the folder on Windows; temp is fine.
      }
    }
  }

  return CodeRun._(go(), () {
    stopped = true;
    process?.kill();
  });
}
