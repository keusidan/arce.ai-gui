/// The answer of the Android side to "does the packaged proot run?" (`ProotProbe.kt`), as text a
/// person can read and copy.
class ProotReport {
  const ProotReport({required this.present, required this.directory, required this.files, required this.steps, this.error});

  factory ProotReport.fromMap(Map<Object?, Object?> map) {
    final steps = <ProotStep>[];
    final raw = map['steps'];
    if (raw is List) {
      for (final step in raw) {
        if (step is Map) {
          steps.add(ProotStep(
            name: '${step['name'] ?? ''}',
            exitCode: step['exit'] is num ? (step['exit']! as num).toInt() : -1,
            output: '${step['output'] ?? ''}'.trim(),
          ));
        }
      }
    }
    final files = map['files'];
    return ProotReport(
      present: map['present'] == true,
      directory: '${map['dir'] ?? ''}',
      files: files is List ? [for (final f in files) '$f'] : const [],
      steps: steps,
      error: map['error'] is String ? map['error']! as String : null,
    );
  }

  final bool present;
  final String directory;
  final List<String> files;
  final List<ProotStep> steps;
  final String? error;

  /// True when proot started a program (the last step ended with 0).
  bool get works => steps.isNotEmpty && steps.last.exitCode == 0 && steps.length >= 2;

  String describe() {
    if (error != null) return '確認できませんでした: $error';
    if (!present) {
      return 'libproot.so がこのアプリに入っていません（この版は proot なしでビルドされたか、この端末の CPU 向けではありません）。\n'
          '場所: $directory\n中身: ${files.isEmpty ? '（空）' : files.join('・')}';
    }
    final lines = <String>[
      for (final step in steps) '${step.exitCode == 0 ? '成功' : '失敗(${step.exitCode})'}  ${step.name}${step.output.isEmpty ? '' : '\n    ${step.output.replaceAll('\n', '\n    ')}'}',
    ];
    lines.add(works ? '→ proot は、この端末で別のプログラムを起動できました。' : '→ proot は起動しましたが、プログラムの実行は成功していません。上の出力を確かめてください。');
    return lines.join('\n');
  }
}

class ProotStep {
  const ProotStep({required this.name, required this.exitCode, required this.output});

  final String name;
  final int exitCode;
  final String output;
}
