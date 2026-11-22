import 'package:flutter_test/flutter_test.dart';
import 'package:notes/editor/code_runner.dart';

void main() {
  test('language names', () {
    expect(runnableLanguage('C++'), 'cpp');
    expect(runnableLanguage('py'), 'python');
    expect(runnableLanguage('js'), 'javascript');
    expect(runnableLanguage('yaml'), isNull);
  });

  test('runs python with Korean output and a non-zero exit', () async {
    if (await findProgram('python') == null) return;
    final r = await runCode(
      'python',
      'import sys\nprint("안녕", 1 + 2)\nprint("err", file=sys.stderr)\nsys.exit(3)',
    ).result;
    expect(r.stdout.trim(), '안녕 3');
    expect(r.stderr.trim(), 'err');
    expect(r.exitCode, 3);
  });

  test('runs javascript', () async {
    if (await findProgram('node') == null) return;
    final r = await runCode(
      'js',
      'console.log([1,2,3].map(x => x * 2).join(","))',
    ).result;
    expect(r.stdout.trim(), '2,4,6');
    expect(r.exitCode, 0);
  });

  test(
    'a run that never ends is stopped by the time limit or by stop()',
    () async {
      if (await findProgram('python') == null) return;
      final slow = await runCode(
        'python',
        'while True: pass',
        timeout: const Duration(seconds: 2),
      ).result;
      expect(slow.timedOut, isTrue);

      final run = runCode('python', 'import time\ntime.sleep(30)');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      run.stop();
      final stopped = await run.result;
      expect(stopped.exitCode, isNull);
      expect(stopped.elapsed.inSeconds, lessThan(10));
    },
  );

  test('C++ either runs or says the compiler is missing', () async {
    final missing =
        await findProgram('g++') == null &&
        await findProgram('clang++') == null;
    final result = runCode(
      'cpp',
      '#include <cstdio>\nint main(){std::puts("안녕 hi");}',
    ).result;
    if (missing) {
      await expectLater(result, throwsA(isA<CodeRunnerException>()));
    } else {
      expect((await result).stdout.trim(), '안녕 hi');
    }
  });
}
