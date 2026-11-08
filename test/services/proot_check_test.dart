import 'package:arce_ai/services/proot_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a build without proot says where it looked and what is there', () {
    final report = ProotReport.fromMap({
      'present': false,
      'dir': '/data/app/ai.arce.app/lib/arm64',
      'files': ['libarce_llama.so', 'libflutter.so'],
    });
    expect(report.works, isFalse);
    final text = report.describe();
    expect(text, contains('libproot.so がこのアプリに入っていません'));
    expect(text, contains('/data/app/ai.arce.app/lib/arm64'));
    expect(text, contains('libarce_llama.so'));
  });

  test('proot that started a program is reported as working', () {
    final report = ProotReport.fromMap({
      'present': true,
      'dir': '/lib',
      'files': ['libproot.so'],
      'steps': [
        {'name': '--version', 'exit': 0, 'output': 'proot 5.1.1\n'},
        {'name': '-r / echo', 'exit': 0, 'output': 'ok\n'},
      ],
    });
    expect(report.works, isTrue);
    final text = report.describe();
    expect(text, contains('成功  --version'));
    expect(text, contains('proot 5.1.1'));
    expect(text, contains('起動できました'));
  });

  test('a start that fails is shown with its exit code and output, also after the retry without seccomp', () {
    final report = ProotReport.fromMap({
      'present': true,
      'dir': '/lib',
      'files': const [],
      'steps': [
        {'name': '--version', 'exit': 0, 'output': 'proot 5.1.1'},
        {'name': '-r / echo', 'exit': 1, 'output': 'proot error: ptrace(TRACEME): Operation not permitted'},
        {'name': '-r / echo (no seccomp)', 'exit': 1, 'output': 'proot error: ptrace(TRACEME): Operation not permitted'},
      ],
    });
    expect(report.works, isFalse);
    final text = report.describe();
    expect(text, contains('失敗(1)'));
    expect(text, contains('Operation not permitted'));
    expect(text, contains('成功していません'));
  });

  test('an error from the platform side is shown as it is', () {
    expect(ProotReport.fromMap({'error': 'boom'}).describe(), contains('boom'));
    expect(ProotReport.fromMap(const {}).describe(), contains('入っていません'));
  });
}
