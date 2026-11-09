/// Commands that are refused on a PC without a sandbox when the approval mode is automatic: the ones that
/// cannot be taken back and reach far past the work (a whole disk, the home folder, the system, the power).
///
/// It is a list of regular expressions the user can edit in the settings (one per line), checked against the
/// whole command, case-insensitively. A list is never complete: it catches the plain ways of writing these
/// commands, not one built out of variables or hidden in a script, which is why the approval mode "毎回確認"
/// exists. An expression that does not compile is skipped, never a reason to refuse everything.
abstract final class DangerousCommands {
  /// What each default expression stands for, in the order of [defaults] (shown in the settings).
  static const defaults = <String>[
    // rm -r of /, /*, ~, $HOME, a drive's root, or everything here and above
    r'''\brm\s+(?:-\S+\s+)*-[a-z]*r[a-z]*\s+(?:-\S+\s+)*(?:--no-preserve-root\s+)?["']?(?:/|/\*|~/?|~/\*|\$HOME/?|\$\{HOME\}/?|\*|\.\./?)["']?(?:\s|;|&|\||$)''',
    r'''--no-preserve-root''',
    // making a file system, writing to a whole disk
    r'''\bmkfs(?:\.\w+)?\b''',
    r'''\bdd\b[^\n;|&]*\bof=/dev/''',
    r'''>\s*/dev/(?:sd|hd|vd|xvd|nvme|mmcblk|disk)\w*''',
    r'''\b(?:wipefs|shred)\b[^\n;|&]*/dev/''',
    // the power
    r'''(?:^|[;&|]\s*|\bsudo\s+)(?:shutdown|reboot|poweroff|halt)\b''',
    r'''\bsystemctl\s+(?:poweroff|reboot|halt|kexec)\b''',
    r'''\b(?:Stop|Restart)-Computer\b''',
    // a fork bomb
    r''':\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:''',
    // the rights or the owner of the whole system
    r'''\bch(?:mod|own|grp)\s+(?:-\S+\s+)*-[a-z]*R[a-z]*\s+\S+\s+/(?:\s|$)''',
    // a download piped straight into a shell
    r'''\b(?:curl|wget|iwr|Invoke-WebRequest)\b[^\n;]*\|\s*(?:sudo\s+)?(?:ba|z|da)?sh\b''',
    r'''\b(?:iex|Invoke-Expression)\b[^\n;]*\b(?:iwr|irm|Invoke-WebRequest|Invoke-RestMethod|DownloadString)\b''',
    // Windows: a drive, the boot, the registry of the machine
    r'''\bformat(?:\.com)?\s+[a-z]:''',
    r'''\bdiskpart\b''',
    r'''\b(?:bcdedit|cipher\s+/w)\b''',
    r'''\breg(?:\.exe)?\s+delete\s+HK(?:LM|EY_LOCAL_MACHINE|CR|EY_CLASSES_ROOT)\b''',
    r'''\b(?:rd|rmdir)\s+(?:/[sq]\s+)+["']?[a-z]:\\?["']?(?:\s|$)''',
    r'''\bdel\s+(?:/[a-z]\s+)*[a-z]:\\\*?''',
    r'''\b(?:Remove-Item|ri|rm)\b[^\n;]*-Recurse\b[^\n;]*\s["']?(?:[a-z]:\\?|~|\$HOME|\$env:USERPROFILE)["']?(?:\s|$)''',
    // a forced push rewrites what others have
    r'''\bgit\s+push\b[^\n;]*(?:\s--force(?:-with-lease)?\b|\s-f\b)''',
  ];

  /// The expression of [patterns] that [command] matches, or null. Lines that are empty or that start with `#`
  /// are not expressions (a note in the settings).
  static String? match(String command, List<String> patterns) {
    for (final pattern in patterns) {
      final source = pattern.trim();
      if (source.isEmpty || source.startsWith('#')) continue;
      final RegExp expression;
      try {
        expression = RegExp(source, caseSensitive: false, multiLine: true);
      } on FormatException {
        continue;
      }
      if (expression.hasMatch(command)) return source;
    }
    return null;
  }

  /// The expressions of [patterns] that do not compile, for the settings screen to point at.
  static List<String> invalid(List<String> patterns) => [
        for (final pattern in patterns)
          if (pattern.trim().isNotEmpty && !pattern.trim().startsWith('#') && !_compiles(pattern.trim())) pattern.trim(),
      ];

  static bool _compiles(String source) {
    try {
      RegExp(source);
      return true;
    } on FormatException {
      return false;
    }
  }
}
